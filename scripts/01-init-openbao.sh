#!/usr/bin/env bash
# ──────────────────────────────────────────────
# OpenBao 초기화 + Unseal + KV 활성화 + AppRole 정책 + Audit (멱등)
#
# 호출자가 BASE_DIR과 ENV_FILE 환경변수를 주입한다.
#
# 단계:
#   1) OpenBao 부팅 대기
#   2) 초기화(필요 시)            → openbao/init-keys.json (Shamir 5/3, root token)
#   3) Unseal (필요 시)
#   4) KV v2 시크릿 엔진 (필요 시) at secret/
#   5) AppRole auth + read-only 정책 + role
#      → role_id / secret_id를 secrets/openbao-approle.env 에 저장 (chmod 600)
#      02-load-secrets.sh가 이 토큰으로 KV read
#   6) File audit device (필요 시) → openbao/logs/audit.log
#
# root_token은 .env에 적지 않는다. 쓰기가 필요한 운영 도구만
# init-keys.json에서 직접 읽는다 (set-openai-key.sh).
# ──────────────────────────────────────────────
set -euo pipefail

: "${BASE_DIR:?BASE_DIR not set}"
: "${ENV_FILE:?ENV_FILE not set}"

INIT_KEYS_FILE="${BASE_DIR}/openbao/init-keys.json"
SECRETS_DIR="${BASE_DIR}/secrets"
APPROLE_FILE="${SECRETS_DIR}/openbao-approle.env"
BAO_ADDR_INTERNAL="http://127.0.0.1:8200"

log() { echo "  [openbao] $*"; }

bao_status_field() {
  local field="$1"
  docker exec openbao bao status -address="$BAO_ADDR_INTERNAL" -format=json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field', ''))" 2>/dev/null \
    || echo ""
}

bao_root() {
  docker exec -e BAO_TOKEN="$ROOT_TOKEN" -e BAO_ADDR="$BAO_ADDR_INTERNAL" openbao bao "$@"
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

# ── 2. 초기화 ──
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

# ── 3. Unseal ──
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

ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${INIT_KEYS_FILE}'))['root_token'])")

# ── 4. KV v2 시크릿 엔진 ──
if ! bao_root secrets list 2>/dev/null | grep -q "^secret/"; then
  log "Enabling KV v2 secrets engine at secret/..."
  bao_root secrets enable -path=secret -version=2 kv >/dev/null
  log "✓ KV engine enabled"
else
  log "KV engine already enabled"
fi

# ── 5. AppRole auth + read-only 정책 ──
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

if ! bao_root auth list 2>/dev/null | grep -q "^approle/"; then
  log "Enabling AppRole auth method..."
  bao_root auth enable approle >/dev/null
  log "✓ AppRole enabled"
else
  log "AppRole already enabled"
fi

# read-only 정책: secret/data/litellm/* 에 대해 read만 허용
log "Writing 'litellm-readonly' policy..."
docker exec -i -e BAO_TOKEN="$ROOT_TOKEN" -e BAO_ADDR="$BAO_ADDR_INTERNAL" openbao \
  bao policy write litellm-readonly - <<'HCL' >/dev/null
path "secret/data/litellm/*" {
  capabilities = ["read"]
}
path "secret/metadata/litellm/*" {
  capabilities = ["read", "list"]
}
HCL
log "✓ Policy 'litellm-readonly' written"

# role 생성/갱신 (멱등)
log "Configuring AppRole 'litellm' role..."
bao_root write auth/approle/role/litellm \
  token_policies="litellm-readonly" \
  token_ttl=1h \
  token_max_ttl=24h \
  secret_id_ttl=0 >/dev/null
log "✓ AppRole role configured"

# role-id (안정) 추출
ROLE_ID=$(bao_root read -format=json auth/approle/role/litellm/role-id \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['role_id'])")

# secret-id: 기존 파일이 있으면 검증 후 재사용, 아니면 새로 발급
NEED_NEW_SECRET_ID=true
if [[ -f "$APPROLE_FILE" ]]; then
  EXISTING_SECRET_ID=$(grep "^OPENBAO_LITELLM_SECRET_ID=" "$APPROLE_FILE" 2>/dev/null | cut -d= -f2-)
  EXISTING_ROLE_ID=$(grep "^OPENBAO_LITELLM_ROLE_ID=" "$APPROLE_FILE" 2>/dev/null | cut -d= -f2-)
  if [[ -n "$EXISTING_SECRET_ID" && "$EXISTING_ROLE_ID" == "$ROLE_ID" ]]; then
    if bao_root write -format=json auth/approle/role/litellm/secret-id/lookup \
         secret_id="$EXISTING_SECRET_ID" 2>/dev/null \
         | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get('data') else 1)" 2>/dev/null; then
      NEED_NEW_SECRET_ID=false
      SECRET_ID="$EXISTING_SECRET_ID"
      log "AppRole secret-id reused from ${APPROLE_FILE}"
    fi
  fi
fi

if $NEED_NEW_SECRET_ID; then
  log "Generating new AppRole secret-id..."
  SECRET_ID=$(bao_root write -format=json -f auth/approle/role/litellm/secret-id \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['secret_id'])")
  log "✓ secret-id generated"
fi

cat > "$APPROLE_FILE" <<EOF
# OpenBao AppRole credentials for LiteLLM read-only access
# Generated by scripts/01-init-openbao.sh — do not edit manually.
OPENBAO_LITELLM_ROLE_ID=${ROLE_ID}
OPENBAO_LITELLM_SECRET_ID=${SECRET_ID}
EOF
chmod 600 "$APPROLE_FILE"
log "✓ AppRole credentials saved to ${APPROLE_FILE}"

# .env에 OPENBAO_ROOT_TOKEN이 잔존하면 제거 (구 버전 마이그레이션)
if grep -q "^OPENBAO_ROOT_TOKEN=" "$ENV_FILE" 2>/dev/null; then
  python3 -c "
import re
p = '$ENV_FILE'
s = open(p).read()
s = re.sub(r'^OPENBAO_ROOT_TOKEN=.*\n?', '', s, flags=re.M)
open(p, 'w').write(s)
"
  log "✓ Removed legacy OPENBAO_ROOT_TOKEN from .env (write ops use init-keys.json directly)"
fi

# ── 6. File audit device ──
# OpenBao는 audit device를 API로 enable할 수 없고 declarative HCL config로만 등록.
# openbao/config/openbao.hcl의 'audit "file" { ... }' 블록이 이 역할을 한다.
# 여기서는 등록 여부 확인만 (대체로 컨테이너 부팅 시점에 활성).
if bao_root audit list 2>/dev/null | grep -q "^file/"; then
  log "Audit device 'file/' is active (config: openbao.hcl)"
else
  log "WARN: audit device not visible. Confirm 'audit \"file\"' block in openbao/config/openbao.hcl"
fi
