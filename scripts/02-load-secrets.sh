#!/usr/bin/env bash
# ──────────────────────────────────────────────
# config/users.conf 의 OPENAI_API_KEY 값을 OpenBao + .env에 동기화
# 흐름:
#   config/users.conf (관리자가 편집한 source)
#         ↓
#   OpenBao (master, 감사/회전을 위해 거쳐가는 저장소)
#         ↓
#   .env  (LiteLLM 컨테이너에 env로 주입되는 캐시)
# ──────────────────────────────────────────────
set -euo pipefail

: "${BASE_DIR:?BASE_DIR not set}"
: "${ENV_FILE:?ENV_FILE not set}"

CONFIG_FILE="${BASE_DIR}/config/users.conf"
INIT_KEYS_FILE="${BASE_DIR}/openbao/init-keys.json"
BAO_ADDR_INTERNAL="http://127.0.0.1:8200"

log() { echo "  [secrets] $*"; }

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "  [secrets] ERROR: ${CONFIG_FILE} not found." >&2
  echo "  [secrets]   Run: cp config/users.conf.example config/users.conf" >&2
  exit 1
fi

# config/users.conf 로드
# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ ${#USERS[@]} -eq 0 ]]; then
  echo "  [secrets] ERROR: USERS array is empty in ${CONFIG_FILE}" >&2
  exit 1
fi

ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${INIT_KEYS_FILE}'))['root_token'])")

# ── Step 1: config/users.conf의 OpenAI Key를 OpenBao에 적재 ──
log "Pushing OpenAI keys from config/users.conf to OpenBao..."
for entry in "${USERS[@]}"; do
  IFS='|' read -r SLOT EMAIL NAME PW KEY <<< "$entry"

  # SLOT은 user01~user10 형식이어야 함
  if [[ ! "$SLOT" =~ ^user[0-9]{2}$ ]]; then
    log "  ✗ Invalid SLOT '$SLOT' (expected userNN). Skipping."
    continue
  fi

  # SLOT의 NN 추출 → USERnn_OPENAI_KEY
  NN="${SLOT#user}"
  VAR_NAME="USER${NN}_OPENAI_KEY"

  docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
    bao kv put -address="$BAO_ADDR_INTERNAL" \
    "secret/litellm/${VAR_NAME}" \
    key="$KEY" >/dev/null
done
log "  ✓ ${#USERS[@]} key(s) written to OpenBao"

# ── Step 2: OpenBao → .env 동기화 ──
log "Syncing OpenBao keys to .env..."

TMP_KEYS=$(mktemp)
trap "rm -f ${TMP_KEYS}" EXIT

# 모든 user01..user10 슬롯에 대해 OpenBao 값 추출
# (config에 없는 슬롯은 placeholder를 OpenBao에 미리 적재)
for i in 01 02 03 04 05 06 07 08 09 10; do
  VAR_NAME="USER${i}_OPENAI_KEY"

  # 이 슬롯에 해당하는 키가 OpenBao에 있는지 확인, 없으면 placeholder 적재
  if ! docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
        bao kv get -address="$BAO_ADDR_INTERNAL" \
        "secret/litellm/${VAR_NAME}" >/dev/null 2>&1; then
    docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
      bao kv put -address="$BAO_ADDR_INTERNAL" \
      "secret/litellm/${VAR_NAME}" \
      key="sk-proj-poc-user${i}-unused-slot-placeholder" >/dev/null
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

log "  ✓ 10 slots synced to .env"
