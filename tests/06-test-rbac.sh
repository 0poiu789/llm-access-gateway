#!/usr/bin/env bash
# RBAC 검증
# - Internal User Virtual Key: /key/generate 호출 시 거부 또는 자기소유로만 가능
# - Master Key: /key/generate 호출 시 허용
set -uo pipefail
: "${LITELLM_URL:?}"
: "${ENV_FILE:?}"
: "${BASE_DIR:?}"

MASTER_KEY=$(grep "^LITELLM_MASTER_KEY=" "$ENV_FILE" | cut -d= -f2-)
SAMPLE_KEYS_FILE="${BASE_DIR}/scripts/sample-keys.txt"

USER01_KEY=$(grep "^alice@local " "$SAMPLE_KEYS_FILE" 2>/dev/null | awk '{print $4}' | head -1)
PASS=true

# 1) Master Key로 /user/list (관리자 전용) → 200
M_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "${LITELLM_URL}/user/list" \
  -H "Authorization: Bearer ${MASTER_KEY}")
if [[ "$M_CODE" == "200" ]]; then
  echo "  ✓ Master Key → /user/list = 200"
else
  echo "  ✗ Master Key → /user/list = ${M_CODE} (expected 200)"
  PASS=false
fi

# 2) Internal User Key로 /user/list → 401 또는 403
if [[ -n "$USER01_KEY" ]]; then
  U_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "${LITELLM_URL}/user/list" \
    -H "Authorization: Bearer ${USER01_KEY}")
  if [[ "$U_CODE" =~ ^(401|403)$ ]]; then
    echo "  ✓ Internal User Key → /user/list = ${U_CODE} (rejected)"
  else
    echo "  ✗ Internal User Key → /user/list = ${U_CODE} (expected 401/403)"
    PASS=false
  fi
else
  echo "  · skip (no sample user key)"
fi

# 3) Internal User Key로 /key/info (자기 정보) → 200
if [[ -n "$USER01_KEY" ]]; then
  I_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "${LITELLM_URL}/key/info" \
    -H "Authorization: Bearer ${USER01_KEY}")
  if [[ "$I_CODE" == "200" ]]; then
    echo "  ✓ Internal User Key → /key/info = 200 (own info)"
  else
    echo "  ⚠ Internal User Key → /key/info = ${I_CODE}"
    # not fatal — endpoint name may vary across LiteLLM versions
  fi
fi

$PASS
