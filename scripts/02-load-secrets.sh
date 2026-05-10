#!/usr/bin/env bash
# ──────────────────────────────────────────────
# OpenBao → .env 동기화 (single source of truth = OpenBao)
#
# 흐름:
#   OpenBao(secret/litellm/USERnn_OPENAI_KEY)  ← 관리자가 직접 적재
#         ↓ (이 스크립트)
#   .env  (LiteLLM 컨테이너 OS env로 주입되는 캐시; 직접 편집 금지)
#
# OpenAI Key 적재 방법(관리자):
#   ./scripts/set-openai-key.sh user01 sk-proj-...
#   또는 OpenBao UI / `bao kv put`
#
# 본 스크립트가 하는 일:
#   1) 모든 user01..user10 슬롯에 대해 OpenBao 값 존재 확인
#      - 없으면 placeholder 한 번만 적재 (실 OpenAI 호출 시 401 반환)
#      - 있으면 그대로 둠 (관리자가 적재한 실 키를 덮어쓰지 않음)
#   2) OpenBao 값을 .env의 USERnn_OPENAI_KEY로 미러링
# ──────────────────────────────────────────────
set -euo pipefail

: "${BASE_DIR:?BASE_DIR not set}"
: "${ENV_FILE:?ENV_FILE not set}"

INIT_KEYS_FILE="${BASE_DIR}/openbao/init-keys.json"
BAO_ADDR_INTERNAL="http://127.0.0.1:8200"

log() { echo "  [secrets] $*"; }

if [[ ! -f "$INIT_KEYS_FILE" ]]; then
  echo "  [secrets] ERROR: ${INIT_KEYS_FILE} not found. Run ./start.sh first to init OpenBao." >&2
  exit 1
fi

ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${INIT_KEYS_FILE}'))['root_token'])")

# ── OpenBao → .env 동기화 ──
log "Syncing OpenBao → .env (10 slots)..."

TMP_KEYS=$(mktemp)
trap "rm -f ${TMP_KEYS}" EXIT

PLACEHOLDER_COUNT=0
REAL_COUNT=0

for i in 01 02 03 04 05 06 07 08 09 10; do
  VAR_NAME="USER${i}_OPENAI_KEY"

  # 슬롯이 OpenBao에 없으면 placeholder 1회 적재 (관리자 키는 절대 덮어쓰지 않음)
  if ! docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
        bao kv get -address="$BAO_ADDR_INTERNAL" \
        "secret/litellm/${VAR_NAME}" >/dev/null 2>&1; then
    docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
      bao kv put -address="$BAO_ADDR_INTERNAL" \
      "secret/litellm/${VAR_NAME}" \
      key="sk-proj-poc-user${i}-placeholder-not-set-yet" >/dev/null
  fi

  VAL=$(docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
    bao kv get -address="$BAO_ADDR_INTERNAL" -format=json "secret/litellm/${VAR_NAME}" \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['data']['data'].get('key', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

  if [[ -z "$VAL" ]]; then
    log "  ✗ Failed to read ${VAR_NAME} from OpenBao"
    exit 1
  fi

  if [[ "$VAL" == *placeholder* ]]; then
    PLACEHOLDER_COUNT=$((PLACEHOLDER_COUNT + 1))
  else
    REAL_COUNT=$((REAL_COUNT + 1))
  fi

  printf '%s=%s\n' "$VAR_NAME" "$VAL" >> "$TMP_KEYS"
done

# Python으로 .env 갱신
ENV_FILE="$ENV_FILE" TMP_KEYS="$TMP_KEYS" python3 - <<'PY'
import os, re

env_path = os.environ["ENV_FILE"]
tmp_keys = os.environ["TMP_KEYS"]

keys = {}
with open(tmp_keys) as f:
    for line in f:
        line = line.rstrip("\n")
        if "=" in line:
            k, v = line.split("=", 1)
            keys[k] = v

s = open(env_path).read()
for var, val in keys.items():
    pattern = rf"^{re.escape(var)}=.*$"
    if re.search(pattern, s, flags=re.M):
        s = re.sub(pattern, f"{var}={val}", s, flags=re.M)
    else:
        if not s.endswith("\n"):
            s += "\n"
        s += f"{var}={val}\n"

open(env_path, "w").write(s)
PY

log "  ✓ Synced 10 slots → .env  (real=${REAL_COUNT}, placeholder=${PLACEHOLDER_COUNT})"
if [[ $PLACEHOLDER_COUNT -gt 0 ]]; then
  log "  ! ${PLACEHOLDER_COUNT} slot(s) still on placeholder."
  log "    Set real OpenAI key:  ./scripts/set-openai-key.sh userNN sk-proj-..."
fi
