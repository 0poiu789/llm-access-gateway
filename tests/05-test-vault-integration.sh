#!/usr/bin/env bash
# OpenBao ↔ LiteLLM 연동 검증
# - OpenBao에 USER01_OPENAI_KEY가 있는지 직접 확인
# - LiteLLM이 모델 목록을 노출한다는 것은 시작 시 vault에서 키를 읽었다는 간접 증거
set -uo pipefail
: "${BASE_DIR:?}"
: "${LITELLM_URL:?}"
: "${ENV_FILE:?}"

INIT_KEYS_FILE="${BASE_DIR}/openbao/init-keys.json"
MASTER_KEY=$(grep "^LITELLM_MASTER_KEY=" "$ENV_FILE" | cut -d= -f2-)

if [[ ! -f "$INIT_KEYS_FILE" ]]; then
  echo "  ✗ ${INIT_KEYS_FILE} not found"
  exit 1
fi

ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${INIT_KEYS_FILE}'))['root_token'])")
PASS=true

# 1) OpenBao에 USER01..10 키 모두 존재
MISSING=0
for i in 01 02 03 04 05 06 07 08 09 10; do
  RESP=$(docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
    bao kv get -address=http://127.0.0.1:8200 -format=json "secret/litellm/USER${i}_OPENAI_KEY" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['data']['data'].get('key', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")
  if [[ -z "$RESP" ]]; then
    echo "  ✗ Missing in vault: secret/litellm/USER${i}_OPENAI_KEY"
    MISSING=$((MISSING+1))
  fi
done

if (( MISSING == 0 )); then
  echo "  ✓ All 10 user keys present in OpenBao"
else
  echo "  ✗ ${MISSING} keys missing in vault"
  PASS=false
fi

# 2) LiteLLM이 모델 목록을 노출 (vault read 성공의 간접 증거)
MODEL_COUNT=$(curl -sk "${LITELLM_URL}/v1/models" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  | python3 -c "
import sys, json
try:
    print(len(json.load(sys.stdin).get('data', [])))
except Exception:
    print(0)
" 2>/dev/null || echo "0")

if (( MODEL_COUNT >= 20 )); then
  echo "  ✓ LiteLLM exposes ${MODEL_COUNT} models (vault keys readable)"
else
  echo "  ✗ LiteLLM exposes only ${MODEL_COUNT} models"
  PASS=false
fi

$PASS
