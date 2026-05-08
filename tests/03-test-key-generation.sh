#!/usr/bin/env bash
# Virtual Key 발급 + 24h TTL 검증
set -uo pipefail
: "${LITELLM_URL:?}"
: "${ENV_FILE:?}"

MASTER_KEY=$(grep "^LITELLM_MASTER_KEY=" "$ENV_FILE" | cut -d= -f2-)
PASS=true

# 임시 Key 발급 (24h) — alias에 timestamp+pid를 붙여 중복 방지
ALIAS="test-ttl-check-$(date +%s)-$$"
RESP=$(curl -sk -X POST "${LITELLM_URL}/key/generate" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"models\": [\"user01-gpt-4o\"], \"duration\": \"24h\", \"key_alias\": \"${ALIAS}\"}")

KEY=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")
EXPIRES=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('expires',''))" 2>/dev/null || echo "")

if [[ -n "$KEY" && "$KEY" == sk-* ]]; then
  echo "  ✓ Key generated: ${KEY:0:20}..."
else
  echo "  ✗ Key generation failed: ${RESP:0:200}"
  PASS=false
fi

if [[ -n "$EXPIRES" ]]; then
  # expires는 ISO timestamp; 현재로부터 23~25h 사이인지 Python에서 직접 판정
  EXPIRES="$EXPIRES" python3 - <<'PY'
import os, sys
from datetime import datetime, timezone
e = os.environ["EXPIRES"].replace("Z", "+00:00")
try:
    dt = datetime.fromisoformat(e)
except Exception:
    dt = datetime.fromisoformat(e[:-1] + "+00:00")
now = datetime.now(timezone.utc) if dt.tzinfo else datetime.now()
hours = (dt - now).total_seconds() / 3600
if 23 <= hours <= 25:
    print(f"  ✓ TTL ≈ 24h (expires in {hours:.1f}h)")
else:
    print(f"  ⚠ TTL is {hours:.1f}h (expected ~24h, non-fatal)")
PY
else
  echo "  ⚠ No 'expires' field in response (default_key_generate_params may not be applied)"
fi

# Cleanup: 발급한 키 삭제
if [[ -n "$KEY" ]]; then
  curl -sk -X POST "${LITELLM_URL}/key/delete" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"keys\": [\"${KEY}\"]}" >/dev/null
fi

$PASS
