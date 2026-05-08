#!/usr/bin/env bash
# 사용자 간 모델 격리 검증
# user01 Key로 user02 모델 호출 시 거부되어야 함
set -uo pipefail
: "${LITELLM_URL:?}"
: "${BASE_DIR:?}"

SAMPLE_KEYS_FILE="${BASE_DIR}/scripts/sample-keys.txt"

if [[ ! -f "$SAMPLE_KEYS_FILE" ]]; then
  echo "  ✗ ${SAMPLE_KEYS_FILE} not found — run scripts/03-register-users.sh first"
  exit 1
fi

# user01의 Virtual Key 추출
USER01_KEY=$(grep "^alice@local " "$SAMPLE_KEYS_FILE" | awk '{print $3}' | head -1)
if [[ -z "$USER01_KEY" ]]; then
  echo "  ✗ Could not find user01 (alice) key in ${SAMPLE_KEYS_FILE}"
  exit 1
fi

echo "  · Using user01 key: ${USER01_KEY:0:20}..."

PASS=true

# 1. user01 자신의 모델은 통과해야 함 (auth 단계까지만; 실제 OpenAI 호출은 placeholder라 실패 OK)
SELF_RESP=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${USER01_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "user01-gpt-4o", "messages": [{"role":"user","content":"hi"}], "max_tokens": 5}')

# 200 (성공) 또는 5xx/4xx (OpenAI placeholder 키 401) 모두 인증/인가 통과를 의미
# 401(LiteLLM 자체) 만 거부 신호
if [[ "$SELF_RESP" == "401" ]]; then
  echo "  ✗ user01 key was REJECTED for own model (HTTP 401)"
  PASS=false
else
  echo "  ✓ user01 key accepted for own model (HTTP ${SELF_RESP})"
fi

# 2. user01 키로 user02 모델 호출 → 거부되어야 함
CROSS_RESP=$(curl -sk -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${USER01_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "user02-gpt-4o", "messages": [{"role":"user","content":"hi"}], "max_tokens": 5}')

CROSS_CODE=$(echo "$CROSS_RESP" | python3 -c "
import sys, json
data = sys.stdin.read()
try:
    d = json.loads(data)
    err = d.get('error', {})
    msg = err.get('message', '')
    code = err.get('code', '')
    # 거부 메시지 키워드
    if any(k in str(msg).lower() for k in ['not allowed', 'no access', 'authentication error', 'team', 'access']):
        print('REJECTED')
    else:
        print('UNCLEAR')
except Exception:
    print('UNCLEAR')
" 2>/dev/null || echo "UNCLEAR")

CROSS_HTTP=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${USER01_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "user02-gpt-4o", "messages": [{"role":"user","content":"hi"}], "max_tokens": 5}')

if [[ "$CROSS_HTTP" =~ ^(400|401|403)$ ]]; then
  echo "  ✓ Cross-user access REJECTED (HTTP ${CROSS_HTTP})"
else
  echo "  ✗ Cross-user access NOT properly rejected (HTTP ${CROSS_HTTP})"
  echo "    Response: ${CROSS_RESP:0:300}"
  PASS=false
fi

$PASS
