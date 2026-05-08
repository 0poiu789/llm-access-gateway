#!/usr/bin/env bash
# ──────────────────────────────────────────────
# 사용자별 OpenAI API Key를 OpenBao에 적재 (placeholder)
# PoC: sk-proj-poc-userNN-placeholder 형태로 저장
# 실 운영: 각 사용자의 실제 OpenAI Key로 교체
# ──────────────────────────────────────────────
set -euo pipefail

: "${BASE_DIR:?BASE_DIR not set}"

INIT_KEYS_FILE="${BASE_DIR}/openbao/init-keys.json"
BAO_ADDR_INTERNAL="http://127.0.0.1:8200"

log() { echo "  [secrets] $*"; }

ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${INIT_KEYS_FILE}'))['root_token'])")

log "Loading 10 user OpenAI key placeholders into OpenBao..."
for i in 01 02 03 04 05 06 07 08 09 10; do
  PLACEHOLDER="sk-proj-poc-user${i}-placeholder-replace-with-real-key"
  docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
    bao kv put -address="$BAO_ADDR_INTERNAL" \
    "secret/litellm/USER${i}_OPENAI_KEY" \
    key="$PLACEHOLDER" \
    >/dev/null
done
log "✓ 10 placeholder keys stored at secret/litellm/USER01..10_OPENAI_KEY"

# 검증: USER01 읽어보기
VAL=$(docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv get -address="$BAO_ADDR_INTERNAL" -format=json secret/litellm/USER01_OPENAI_KEY \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['data']['key'])")

if [[ "$VAL" == sk-proj-poc-user01-* ]]; then
  log "✓ Read-back verification successful"
else
  log "✗ Read-back verification FAILED: got '${VAL}'"
  exit 1
fi
