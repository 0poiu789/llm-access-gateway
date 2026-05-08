#!/usr/bin/env bash
# ──────────────────────────────────────────────
# config/users.conf 기반 사용자 등록 + Virtual Key 발급
# 멱등 동작:
#   - 사용자가 없으면 /user/new 로 신규 생성
#   - 있으면 /user/update 로 패스워드/모델 갱신
#   - 매 실행마다 새 24h Virtual Key 발급 (구 키는 24h 후 자동 만료)
# 결과: scripts/sample-keys.txt
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
  echo "# Format: <email> <slot> <virtual_key>"
  echo ""
} >> "$SAMPLE_KEYS_FILE"

# ── 일반 사용자 처리 ──
log "Registering ${#USERS[@]} internal user(s) from config/users.conf..."
for entry in "${USERS[@]}"; do
  IFS='|' read -r SLOT EMAIL NAME PW KEY <<< "$entry"

  if [[ ! "$SLOT" =~ ^user[0-9]{2}$ ]]; then
    log "  ✗ Invalid SLOT '$SLOT', skipping"
    continue
  fi

  PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'user_email': '${EMAIL}',
    'user_role': 'internal_user',
    'password': '${PW}',
    'models': ['${SLOT}-gpt-4o', '${SLOT}-o3-mini'],
    'max_budget': 50.0,
    'budget_duration': '30d',
    'metadata': {'slot': '${SLOT}', 'name': '${NAME}'}
}, ensure_ascii=False))
")

  if [[ "$(user_exists "$EMAIL")" == "NO" ]]; then
    log "  + create ${EMAIL} → ${SLOT} (pw: ${PW})"
    curl $CURL_OPTS -X POST "${LITELLM_URL}/user/new" \
      -H "Authorization: Bearer ${MASTER_KEY}" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" >/dev/null
  else
    log "  ↻ update ${EMAIL} → ${SLOT} (pw/모델 동기화)"
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
    echo "${EMAIL} ${SLOT} ${VKEY}" >> "$SAMPLE_KEYS_FILE"
  else
    log "  ✗ Failed to issue key for ${EMAIL}: ${KEY_RESP:0:200}"
  fi
done

# ── 관리자 처리 ──
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin-pw-change-me}"

ADMIN_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'user_email': '${ADMIN_EMAIL}',
    'user_role': 'proxy_admin',
    'password': '${ADMIN_PASSWORD}'
}))
")

if [[ "$(user_exists "$ADMIN_EMAIL")" == "NO" ]]; then
  log "Creating admin: ${ADMIN_EMAIL} (pw: ${ADMIN_PASSWORD})"
  curl $CURL_OPTS -X POST "${LITELLM_URL}/user/new" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "$ADMIN_PAYLOAD" >/dev/null
else
  log "Updating admin: ${ADMIN_EMAIL} (pw 동기화)"
  curl $CURL_OPTS -X POST "${LITELLM_URL}/user/update" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "$ADMIN_PAYLOAD" >/dev/null || true
fi

NUM_KEYS=$(grep -c '^[^#]' "$SAMPLE_KEYS_FILE" 2>/dev/null || echo "0")
NUM_KEYS=$(echo "$NUM_KEYS" | tr -d '\n')
log "✓ Registered ${#USERS[@]} user(s) + admin, issued $((NUM_KEYS - 1)) virtual key(s)"
log "  Keys saved: ${SAMPLE_KEYS_FILE}"
