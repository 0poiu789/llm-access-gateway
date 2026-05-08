#!/usr/bin/env bash
# ──────────────────────────────────────────────
# OpenBao 초기화 + Unseal + KV 활성화 (멱등)
# 호출자가 BASE_DIR과 ENV_FILE 환경변수를 주입한다.
# ──────────────────────────────────────────────
set -euo pipefail

: "${BASE_DIR:?BASE_DIR not set}"
: "${ENV_FILE:?ENV_FILE not set}"

INIT_KEYS_FILE="${BASE_DIR}/openbao/init-keys.json"
BAO_ADDR_INTERNAL="http://127.0.0.1:8200"

log() { echo "  [openbao] $*"; }

# OpenBao status를 JSON으로 받아 특정 키 추출 (python3 사용)
bao_status_field() {
  local field="$1"
  docker exec openbao bao status -address="$BAO_ADDR_INTERNAL" -format=json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field', ''))" 2>/dev/null \
    || echo ""
}

# ── 1. status 폴링 ──
log "Waiting for OpenBao to accept connections..."
for i in $(seq 1 30); do
  if docker exec openbao bao status -address="$BAO_ADDR_INTERNAL" >/dev/null 2>&1 \
     || [[ $(bao_status_field "initialized") != "" ]]; then
    break
  fi
  sleep 1
done

# ── 2. 초기화 (필요 시) ──
INITIALIZED=$(bao_status_field "initialized")
if [[ "$INITIALIZED" != "True" && "$INITIALIZED" != "true" ]]; then
  log "Initializing OpenBao (Shamir 5/3)..."
  docker exec openbao bao operator init \
    -key-shares=5 -key-threshold=3 -format=json \
    -address="$BAO_ADDR_INTERNAL" \
    > "$INIT_KEYS_FILE"
  chmod 600 "$INIT_KEYS_FILE"
  log "✓ Initialized. Keys saved to ${INIT_KEYS_FILE} (chmod 600)"
  log "*** BACKUP ${INIT_KEYS_FILE} OFFLINE AND DELETE FROM SERVER IN PRODUCTION ***"
else
  log "Already initialized, skipping init"
  if [[ ! -f "$INIT_KEYS_FILE" ]]; then
    echo "  [openbao] ERROR: ${INIT_KEYS_FILE} missing but Vault is initialized." >&2
    echo "  [openbao] Cannot recover root token. Run ./reset.sh and start over." >&2
    exit 1
  fi
fi

# ── 3. Unseal (필요 시) ──
SEALED=$(bao_status_field "sealed")
if [[ "$SEALED" == "True" || "$SEALED" == "true" ]]; then
  log "Unsealing..."
  for i in 0 1 2; do
    KEY=$(python3 -c "import json; print(json.load(open('${INIT_KEYS_FILE}'))['unseal_keys_b64'][$i])")
    docker exec openbao bao operator unseal -address="$BAO_ADDR_INTERNAL" "$KEY" >/dev/null
  done
  log "✓ Unsealed"
else
  log "Already unsealed"
fi

# ── 4. Root Token을 .env에 기록 ──
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${INIT_KEYS_FILE}'))['root_token'])")
if grep -q "^OPENBAO_ROOT_TOKEN=" "$ENV_FILE"; then
  # In-place update (compatible with both BSD and GNU sed)
  python3 -c "
import re, sys
p = '$ENV_FILE'
t = '$ROOT_TOKEN'
s = open(p).read()
s = re.sub(r'^OPENBAO_ROOT_TOKEN=.*$', f'OPENBAO_ROOT_TOKEN={t}', s, flags=re.M)
open(p, 'w').write(s)
"
else
  echo "OPENBAO_ROOT_TOKEN=${ROOT_TOKEN}" >> "$ENV_FILE"
fi
log "✓ Root Token written to .env"

# ── 5. KV 시크릿 엔진 활성화 (필요 시) ──
if ! docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
     bao secrets list -address="$BAO_ADDR_INTERNAL" 2>/dev/null | grep -q "^secret/"; then
  log "Enabling KV v2 secrets engine at secret/..."
  docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
    bao secrets enable -address="$BAO_ADDR_INTERNAL" -path=secret -version=2 kv >/dev/null
  log "✓ KV engine enabled"
else
  log "KV engine already enabled"
fi
