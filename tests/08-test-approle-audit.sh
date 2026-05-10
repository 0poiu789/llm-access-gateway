#!/usr/bin/env bash
# 08 — OpenBao AppRole 정책 + Audit log 검증
#
# 검증:
#   (a) AppRole 토큰으로 KV read 성공
#   (b) AppRole 토큰으로 KV write 거부됨 (정책이 read-only)
#   (c) audit log에 read/write 이벤트가 기록됨
set -uo pipefail
: "${BASE_DIR:?}"

APPROLE_FILE="${BASE_DIR}/secrets/openbao-approle.env"
AUDIT_LOG_PATH_IN_CONTAINER="/openbao/logs/audit.log"
BAO_ADDR_INTERNAL="http://127.0.0.1:8200"

if [[ ! -f "$APPROLE_FILE" ]]; then
  echo "  ✗ ${APPROLE_FILE} not found — AppRole bootstrap missing"
  exit 1
fi

# shellcheck disable=SC1090
source "$APPROLE_FILE"

if [[ -z "${OPENBAO_LITELLM_ROLE_ID:-}" || -z "${OPENBAO_LITELLM_SECRET_ID:-}" ]]; then
  echo "  ✗ AppRole credentials missing"
  exit 1
fi

PASS=true

# (a) AppRole 로그인
TOKEN=$(docker exec openbao bao write -address="$BAO_ADDR_INTERNAL" \
  -format=json auth/approle/login \
  role_id="$OPENBAO_LITELLM_ROLE_ID" \
  secret_id="$OPENBAO_LITELLM_SECRET_ID" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['auth']['client_token'])" 2>/dev/null)

if [[ -z "$TOKEN" ]]; then
  echo "  ✗ AppRole login failed"
  exit 1
fi
echo "  · AppRole login OK"

# (b) read 성공
if docker exec -e BAO_TOKEN="$TOKEN" openbao bao kv get \
   -address="$BAO_ADDR_INTERNAL" "secret/litellm/USER01_OPENAI_KEY" >/dev/null 2>&1; then
  echo "  ✓ Read of secret/litellm/USER01_OPENAI_KEY allowed"
else
  echo "  ✗ Read denied (policy or missing key)"
  PASS=false
fi

# (c) write 거부 — 임의의 시도. 정책이 올바르면 permission denied
WRITE_OUT=$(docker exec -e BAO_TOKEN="$TOKEN" openbao bao kv put \
  -address="$BAO_ADDR_INTERNAL" \
  "secret/litellm/USER99_OPENAI_KEY" key=should-be-blocked 2>&1 || true)

if echo "$WRITE_OUT" | grep -qiE "permission denied|403"; then
  echo "  ✓ Write blocked by policy (read-only enforced)"
else
  echo "  ✗ Write was NOT blocked: ${WRITE_OUT:0:200}"
  PASS=false
fi

# (d) audit log 파일 존재 + JSON 라인 최소 1개 이상.
# audit.log는 컨테이너 uid 999로 chmod 600이라 호스트에서 직접 읽지 못함 → docker exec.
N=$(docker exec openbao sh -c "grep -c '\"type\":\"request\"\|\"type\":\"response\"' ${AUDIT_LOG_PATH_IN_CONTAINER} 2>/dev/null || echo 0" | tr -d '\n ')
if [[ "$N" =~ ^[0-9]+$ ]] && (( N > 0 )); then
  echo "  ✓ Audit log present with ${N} entries (read via docker exec)"
else
  echo "  ✗ Audit log empty or missing: ${AUDIT_LOG_PATH_IN_CONTAINER} (entries=${N})"
  PASS=false
fi

$PASS
