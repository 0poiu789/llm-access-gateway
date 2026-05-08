#!/usr/bin/env bash
# 모델 20개 (user01~user10 × {gpt-4o, o3-mini}) 노출 확인
set -uo pipefail
: "${LITELLM_URL:?}"
: "${ENV_FILE:?}"

MASTER_KEY=$(grep "^LITELLM_MASTER_KEY=" "$ENV_FILE" | cut -d= -f2-)
PASS=true

RESP=$(curl -sk "${LITELLM_URL}/v1/models" \
  -H "Authorization: Bearer ${MASTER_KEY}")

# 모델 카운트
COUNT=$(echo "$RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    ids = [m['id'] for m in d.get('data', [])]
    print(len(ids))
except Exception:
    print(0)
")

if [[ "$COUNT" -ge 20 ]]; then
  echo "  ✓ ${COUNT} models exposed"
else
  echo "  ✗ Expected at least 20 models, got ${COUNT}"
  echo "    Raw response: ${RESP:0:300}"
  PASS=false
fi

# 특정 모델명 존재 확인
for slot in user01 user05 user10; do
  for m in gpt-4o o3-mini; do
    if echo "$RESP" | grep -q "\"${slot}-${m}\""; then
      :
    else
      echo "  ✗ Missing model: ${slot}-${m}"
      PASS=false
    fi
  done
done
[[ "$PASS" == "true" ]] && echo "  ✓ All expected user-specific models present"

$PASS
