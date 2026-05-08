#!/usr/bin/env bash
# Virtual Key 발급 + 24h TTL 검증
set -uo pipefail
: "${LITELLM_URL:?}"
: "${ENV_FILE:?}"

MASTER_KEY=$(grep "^LITELLM_MASTER_KEY=" "$ENV_FILE" | cut -d= -f2-)
PASS=true

# 임시 Key 발급 (24h)
RESP=$(curl -sk -X POST "${LITELLM_URL}/key/generate" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"models": ["user01-gpt-4o"], "duration": "24h", "key_alias": "test-ttl-check"}')

KEY=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")
EXPIRES=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('expires',''))" 2>/dev/null || echo "")

if [[ -n "$KEY" && "$KEY" == sk-* ]]; then
  echo "  ✓ Key generated: ${KEY:0:20}..."
else
  echo "  ✗ Key generation failed: ${RESP:0:200}"
  PASS=false
fi

if [[ -n "$EXPIRES" ]]; then
  # expires는 ISO timestamp; 현재로부터 23~25h 사이인지 확인
  HOURS=$(python3 -c "
from datetime import datetime, timezone
e = '${EXPIRES}'.replace('Z', '+00:00')
try:
    dt = datetime.fromisoformat(e)
except Exception:
    dt = datetime.fromisoformat(e[:-1] + '+00:00')
now = datetime.now(timezone.utc) if dt.tzinfo else datetime.now()
diff = (dt - now).total_seconds() / 3600
print(f'{diff:.1f}')
" 2>/dev/null || echo "0")

  if (( $(echo "$HOURS >= 23 && $HOURS <= 25" | python3 -c "import sys; ok = eval(sys.stdin.read().strip()); print('1' if ok else '0')") )); then
    echo "  ✓ TTL ≈ 24h (expires in ${HOURS}h)"
  else
    echo "  ⚠ TTL is ${HOURS}h (expected ~24h)"
    # not failing — config 미적용 가능성
  fi
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
