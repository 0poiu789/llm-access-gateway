#!/usr/bin/env bash
# ──────────────────────────────────────────────
# config/users.conf 기반 사용자 등록 + Virtual Key 발급
#
# 흐름:
#   1) config/users.conf의 USERS 배열을 읽음 (4-field 형식: SLOT|EMAIL|NAME|OPENAI_KEY)
#   2) 각 사용자마다 LiteLLM /user/new (없으면) 또는 /user/update (있으면)
#      ※ password 필드는 사용하지 않음 (LiteLLM OSS의 UI password 로그인 버그 회피).
#         사용자는 UI에 로그인하지 않고 발급된 Virtual Key를 API/CLI에 사용한다.
#   3) 매 실행마다 새 24h Virtual Key 발급 (구 키는 24h 후 자동 만료)
#   4) 결과를 scripts/sample-keys.txt에 기록 (관리자가 사용자에게 안전 채널로 전달)
# ──────────────────────────────────────────────
set -euo pipefail

: "${BASE_DIR:?BASE_DIR not set}"
: "${ENV_FILE:?ENV_FILE not set}"

LITELLM_URL="${LITELLM_URL:-https://localhost}"
CURL_OPTS="-sk"

CONFIG_FILE="${BASE_DIR}/config/users.conf"
SAMPLE_KEYS_FILE="${BASE_DIR}/scripts/sample-keys.txt"

log() { echo "  [users] $*"; }

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "  [users] ERROR: ${CONFIG_FILE} not found." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

MASTER_KEY=$(grep "^LITELLM_MASTER_KEY=" "$ENV_FILE" | cut -d= -f2-)

# ── 헬퍼: 사용자 존재 여부 ──
user_exists() {
  local email="$1"
  local resp
  resp=$(curl $CURL_OPTS -X GET "${LITELLM_URL}/user/info?user_email=${email}" \
    -H "Authorization: Bearer ${MASTER_KEY}" 2>/dev/null || echo "{}")
  echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    info = d.get('user_info') or d.get('user_id') or d.get('user_email')
    print('YES' if info else 'NO')
except Exception:
    print('NO')
"
}

# ── sample-keys.txt 헤더 초기화 ──
> "$SAMPLE_KEYS_FILE"
{
  echo "# Generated $(date -Iseconds) — DO NOT COMMIT"
  echo "# 각 줄을 해당 사용자에게 안전한 채널(사내 메신저 다이렉트, 이메일)로 전달."
  echo "# 24시간 후 만료. 매일 또는 필요 시 ./start.sh 재실행하여 갱신."
  echo "#"
  echo "# Format: <email> <slot> <name> <virtual_key>"
  echo ""
} >> "$SAMPLE_KEYS_FILE"

# ── 일반 사용자 처리 ──
log "Registering ${#USERS[@]} internal user(s) from config/users.conf..."
for entry in "${USERS[@]}"; do
  IFS='|' read -r SLOT EMAIL NAME KEY <<< "$entry"

  if [[ ! "$SLOT" =~ ^user[0-9]{2}$ ]]; then
    log "  ✗ Invalid SLOT '$SLOT', skipping"
    continue
  fi

  # /user/new 또는 /user/update 페이로드 — password 필드는 의도적으로 제외
  # (LiteLLM OSS의 UI password 로그인 버그 회피; 사용자는 Virtual Key API로 사용)
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'user_email': '${EMAIL}',
    'user_role': 'internal_user',
    'models': ['${SLOT}-gpt-4o', '${SLOT}-o3-mini'],
    'max_budget': 50.0,
    'budget_duration': '30d',
    'metadata': {'slot': '${SLOT}', 'name': '${NAME}'},
    'auto_create_key': False
}, ensure_ascii=False))
")

  if [[ "$(user_exists "$EMAIL")" == "NO" ]]; then
    log "  + create ${EMAIL} → ${SLOT}"
    curl $CURL_OPTS -X POST "${LITELLM_URL}/user/new" \
      -H "Authorization: Bearer ${MASTER_KEY}" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" >/dev/null
  else
    log "  ↻ update ${EMAIL} → ${SLOT}"
    curl $CURL_OPTS -X POST "${LITELLM_URL}/user/update" \
      -H "Authorization: Bearer ${MASTER_KEY}" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" >/dev/null || true
  fi

  # Virtual Key 발급 (24h)
  KEY_RESP=$(curl $CURL_OPTS -X POST "${LITELLM_URL}/key/generate" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"user_id\": \"${EMAIL}\",
      \"models\": [\"${SLOT}-gpt-4o\", \"${SLOT}-o3-mini\"],
      \"duration\": \"24h\",
      \"key_alias\": \"${SLOT}-codex-$(date +%Y%m%d-%H%M%S)\",
      \"metadata\": {\"slot\": \"${SLOT}\", \"purpose\": \"codex-cli\"}
    }")

  VKEY=$(echo "$KEY_RESP" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('key', ''))
except Exception:
    print('')
")

  if [[ -n "$VKEY" && "$VKEY" == sk-* ]]; then
    echo "${EMAIL} ${SLOT} ${NAME} ${VKEY}" >> "$SAMPLE_KEYS_FILE"
  else
    log "  ✗ Failed to issue key for ${EMAIL}: ${KEY_RESP:0:200}"
  fi
done

# ── 관리자 처리 (Master Key로 UI 로그인하므로 password 불필요) ──
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@local}"
ADMIN_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'user_email': '${ADMIN_EMAIL}',
    'user_role': 'proxy_admin'
}))
")

if [[ "$(user_exists "$ADMIN_EMAIL")" == "NO" ]]; then
  log "Creating admin: ${ADMIN_EMAIL} (UI login: admin / Master Key)"
  curl $CURL_OPTS -X POST "${LITELLM_URL}/user/new" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "$ADMIN_PAYLOAD" >/dev/null
else
  log "Admin user already exists: ${ADMIN_EMAIL}"
fi

NUM_KEYS=$(grep -c '^[^#]' "$SAMPLE_KEYS_FILE" 2>/dev/null || echo "0")
NUM_KEYS=$(echo "$NUM_KEYS" | tr -d '\n ')
log "✓ Registered ${#USERS[@]} user(s), issued $((NUM_KEYS - 1)) virtual key(s)"
log "  Distribute keys from: ${SAMPLE_KEYS_FILE}"
