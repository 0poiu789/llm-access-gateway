#!/usr/bin/env bash
# ──────────────────────────────────────────────
# OpenBao를 사용자별 OpenAI Key의 source of truth로 운영하되,
# LiteLLM OSS가 vault 연동을 지원하지 않으므로
#   - 최초: placeholder 키를 OpenBao에 적재
#   - 매 실행: OpenBao의 현재 값을 .env로 동기화
# 이로써 OpenBao에서 키를 갱신하면 ./start.sh 재실행만으로 LiteLLM에 반영된다.
# ──────────────────────────────────────────────
set -euo pipefail

: "${BASE_DIR:?BASE_DIR not set}"
: "${ENV_FILE:?ENV_FILE not set}"

INIT_KEYS_FILE="${BASE_DIR}/openbao/init-keys.json"
BAO_ADDR_INTERNAL="http://127.0.0.1:8200"

log() { echo "  [secrets] $*"; }

ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${INIT_KEYS_FILE}'))['root_token'])")

# ── Step 1: 키가 없으면 placeholder 적재 (있으면 보존) ──
log "Ensuring 10 user OpenAI keys exist in OpenBao..."
CREATED=0
PRESERVED=0
for i in 01 02 03 04 05 06 07 08 09 10; do
  if docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
       bao kv get -address="$BAO_ADDR_INTERNAL" "secret/litellm/USER${i}_OPENAI_KEY" \
       >/dev/null 2>&1; then
    PRESERVED=$((PRESERVED+1))
  else
    PLACEHOLDER="sk-proj-poc-user${i}-placeholder-replace-with-real-key"
    docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
      bao kv put -address="$BAO_ADDR_INTERNAL" \
      "secret/litellm/USER${i}_OPENAI_KEY" \
      key="$PLACEHOLDER" >/dev/null
    CREATED=$((CREATED+1))
  fi
done
log "  ✓ ${CREATED} placeholder(s) created, ${PRESERVED} existing key(s) preserved"

# ── Step 2: OpenBao → .env 동기화 ──
# Python으로 안전하게 처리 (인용 이슈 방지)
log "Syncing OpenBao keys to .env (consumed by LiteLLM container)..."

# 임시 파일에 KEY=VALUE 라인 작성
TMP_KEYS=$(mktemp)
trap "rm -f ${TMP_KEYS}" EXIT

for i in 01 02 03 04 05 06 07 08 09 10; do
  VAR="USER${i}_OPENAI_KEY"
  VAL=$(docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
    bao kv get -address="$BAO_ADDR_INTERNAL" -format=json "secret/litellm/USER${i}_OPENAI_KEY" \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['data']['data'].get('key', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

  if [[ -z "$VAL" ]]; then
    log "  ✗ Failed to read ${VAR} from OpenBao"
    exit 1
  fi
  printf '%s=%s\n' "$VAR" "$VAL" >> "$TMP_KEYS"
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

log "  ✓ 10 keys synced to .env"
log "  · LiteLLM picks these up via docker-compose substitution on next 'up'"
