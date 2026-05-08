#!/usr/bin/env bash
# ──────────────────────────────────────────────
# LLM Access Gateway — 본인 정보 조회 스크립트 (사용자 배포용)
#
# 사용법:
#   export OPENAI_API_KEY="sk-vk-..."           # 관리자에게 받은 Virtual Key
#   export GATEWAY_URL="https://<서버주소>"     # (선택, 기본: https://localhost)
#   ./check-info.sh
#
# 출력: 본인 Key의 spend, max_budget, 잔여 예산, 만료 시각, 허용 모델
# ──────────────────────────────────────────────
set -euo pipefail

VKEY="${OPENAI_API_KEY:-}"
URL="${GATEWAY_URL:-https://localhost}"

if [[ -z "$VKEY" ]]; then
  echo "✗ OPENAI_API_KEY 환경변수가 설정되지 않았습니다." >&2
  echo "  example: export OPENAI_API_KEY=\"sk-vk-...\"" >&2
  exit 1
fi

RESP=$(curl -sk "${URL}/key/info" -H "Authorization: Bearer ${VKEY}" 2>/dev/null || echo "{}")

echo "$RESP" | python3 - <<PY
import sys, json
from datetime import datetime, timezone
data = json.loads('''$RESP''')
info = data.get("info") or data
if not info or "key_alias" not in info:
    print("✗ 응답이 정상적이지 않습니다. Virtual Key가 만료되었거나 게이트웨이 주소가 잘못됐을 수 있습니다.")
    print("  Raw response:", json.dumps(data)[:300])
    sys.exit(1)

spend = info.get("spend", 0) or 0
max_budget = info.get("max_budget", 0) or 0
remaining = max_budget - spend
expires = info.get("expires") or info.get("expires_at")

if expires:
    e = expires.replace("Z", "+00:00") if expires.endswith("Z") else expires
    try:
        dt = datetime.fromisoformat(e)
    except Exception:
        dt = None
    if dt:
        now = datetime.now(timezone.utc) if dt.tzinfo else datetime.now()
        delta = dt - now
        hours = delta.total_seconds() / 3600
        expires_str = f"{dt.isoformat()} ({hours:+.1f}h)"
    else:
        expires_str = expires
else:
    expires_str = "(만료 시각 없음)"

print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print(" LLM Access Gateway — 사용량 리포트")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print(f"  Key alias:    {info.get('key_alias', 'N/A')}")
print(f"  사용 금액:     \${spend:.4f}")
print(f"  월 한도:       \${max_budget:.2f}  (예산 주기: {info.get('budget_duration', 'N/A')})")
print(f"  잔여 예산:     \${remaining:.4f}")
print(f"  만료 시각:     {expires_str}")
print(f"  허용 모델:     {', '.join(info.get('models', []))}")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("  Key가 24h 안에 만료되면 관리자에게 새 키를 요청하세요.")
PY
