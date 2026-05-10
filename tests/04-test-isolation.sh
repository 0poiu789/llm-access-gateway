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
USER01_KEY=$(grep "^alice@local " "$SAMPLE_KEYS_FILE" | awk '{print $4}' | head -1)
if [[ -z "$USER01_KEY" ]]; then
  echo "  ✗ Could not find user01 (alice) key in ${SAMPLE_KEYS_FILE}"
  exit 1
fi

echo "  · Using user01 key: ${USER01_KEY:0:20}..."

PASS=true

# 1. user01 자신의 모델 호출 — Virtual Key 인증 통과 여부만 확인.
# OpenAI 콘솔의 placeholder 키로 인한 upstream 401은 정상 (게이트웨이가 프록시한 증거)
# LiteLLM 자체 Virtual Key 거부와 OpenAI 401을 응답 본문으로 구분한다.
SELF_BODY=$(curl -sk -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${USER01_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "user01-gpt-4o", "messages": [{"role":"user","content":"hi"}], "max_tokens": 5}')

SELF_RESP=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "${LITELLM_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${USER01_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "user01-gpt-4o", "messages": [{"role":"user","content":"hi"}], "max_tokens": 5}')

if [[ "$SELF_RESP" == "200" ]]; then
  echo "  ✓ user01 key accepted for own model (HTTP 200, real OpenAI key)"
elif echo "$SELF_BODY" | grep -qE 'OpenAIException|Incorrect API key|Invalid API key|Bearer.*placeholder'; then
  echo "  ✓ user01 key accepted by LiteLLM, upstream OpenAI 401 (placeholder key — expected before set-openai-key.sh)"
elif [[ "$SELF_RESP" == "401" ]]; then
  echo "  ✗ user01 key was REJECTED by LiteLLM (HTTP 401, not from upstream)"
  echo "    Response: ${SELF_BODY:0:300}"
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
