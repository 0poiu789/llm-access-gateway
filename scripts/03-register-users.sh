#!/usr/bin/env bash
# ──────────────────────────────────────────────
# LiteLLM에 사용자 사전등록 + Virtual Key 발급 (멱등)
# 결과: scripts/sample-keys.txt
# ──────────────────────────────────────────────
set -euo pipefail

: "${BASE_DIR:?BASE_DIR not set}"
: "${ENV_FILE:?ENV_FILE not set}"

LITELLM_URL="${LITELLM_URL:-https://localhost}"
CURL_OPTS="-sk"  # -k for self-signed cert

MASTER_KEY=$(grep "^LITELLM_MASTER_KEY=" "$ENV_FILE" | cut -d= -f2-)
SAMPLE_KEYS_FILE="${BASE_DIR}/scripts/sample-keys.txt"

log() { echo "  [users] $*"; }

# 매핑 테이블 (PoC 기본값)
USERS=(
  "alice@local user01 홍길동"
  "bob@local user02 김철수"
  "carol@local user03 이영희"
  "dave@local user04 박민수"
  "eve@local user05 최지은"
  "frank@local user06 정서연"
  "grace@local user07 강도현"
  "henry@local user08 윤하은"
  "ivy@local user09 장현우"
  "jack@local user10 한소율"
)
ADMIN_EMAIL="admin@local"

# JSON 파싱 유틸 (jq 없는 환경 대응)
json_field() {
  python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('$1', ''))" 2>/dev/null || echo ""
}

# ── /user/info 로 존재 확인 ──
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

# ── 헤더 ──
> "$SAMPLE_KEYS_FILE"
echo "# Generated $(date -Iseconds) — DO NOT COMMIT" >> "$SAMPLE_KEYS_FILE"
echo "# Format: <email> <slot> <virtual_key>" >> "$SAMPLE_KEYS_FILE"
echo "" >> "$SAMPLE_KEYS_FILE"

# ── Internal Users ──
log "Registering 10 internal users..."
for entry in "${USERS[@]}"; do
  read -r EMAIL SLOT NAME <<< "$entry"

  if [[ "$(user_exists "$EMAIL")" == "NO" ]]; then
    log "  + create ${EMAIL} → ${SLOT}"
    curl $CURL_OPTS -X POST "${LITELLM_URL}/user/new" \
      -H "Authorization: Bearer ${MASTER_KEY}" \
      -H "Content-Type: application/json" \
      -d "{
        \"user_email\": \"${EMAIL}\",
        \"user_role\": \"internal_user\",
        \"models\": [\"${SLOT}-gpt-4o\", \"${SLOT}-o3-mini\"],
        \"max_budget\": 50.0,
        \"budget_duration\": \"30d\",
        \"metadata\": {\"slot\": \"${SLOT}\", \"name\": \"${NAME}\"}
      }" >/dev/null
  else
    log "  · ${EMAIL} already exists"
  fi

  # Virtual Key 발급 (24h)
  KEY_RESP=$(curl $CURL_OPTS -X POST "${LITELLM_URL}/key/generate" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"user_id\": \"${EMAIL}\",
      \"models\": [\"${SLOT}-gpt-4o\", \"${SLOT}-o3-mini\"],
      \"duration\": \"24h\",
      \"key_alias\": \"${SLOT}-codex-$(date +%Y%m%d)\",
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

# ── Admin ──
log "Registering admin user..."
if [[ "$(user_exists "$ADMIN_EMAIL")" == "NO" ]]; then
  curl $CURL_OPTS -X POST "${LITELLM_URL}/user/new" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"user_email\": \"${ADMIN_EMAIL}\",
      \"user_role\": \"proxy_admin\"
    }" >/dev/null
  log "  + ${ADMIN_EMAIL} (proxy_admin)"
else
  log "  · ${ADMIN_EMAIL} already exists"
fi

NUM_KEYS=$(grep -c '^[a-z]' "$SAMPLE_KEYS_FILE" || echo "0")
log "✓ ${NUM_KEYS} virtual keys saved to ${SAMPLE_KEYS_FILE}"
