#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════
# LLM Access Gateway — 단일 진입점 부트스트랩 + 검증 스크립트
#   - 멱등 (여러 번 실행해도 안전)
#   - 최초 실행: .env 생성, TLS 자체서명 인증서 발급, OpenBao 초기화
#   - 후속 실행: 기존 상태 보존, 누락 부분만 보완
# ══════════════════════════════════════════════════════════
set -euo pipefail

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ENV_FILE="${BASE_DIR}/.env"
INIT_KEYS_FILE="${BASE_DIR}/openbao/init-keys.json"
LITELLM_URL="${LITELLM_URL:-https://localhost}"

export BASE_DIR ENV_FILE LITELLM_URL

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '\033[1;36m▸\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# 호스트의 outbound IP 감지 (PROXY_BASE_URL 기본값으로 사용)
detect_host_ip() {
  local ip
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  if [[ -z "$ip" || "$ip" == "127.0.0.1" ]]; then
    ip="localhost"
  fi
  echo "$ip"
}

# ════════════════════════════════════════════
# 개인 개발용 TLS — Local Root CA + Root-signed leaf
# ════════════════════════════════════════════
# 배경: 단일 self-signed server.crt는 codex(rustls)가 거부한다 —
#   - basicConstraints CA:TRUE 가 박혀있으면 CaUsedAsEndEntity
#   - trust 안 된 issuer면 UnknownIssuer
# 해결: 별도 Root CA(local-root-ca.crt)를 만들어 OS trust store에 등록하고,
#       서버 cert(server.crt)은 그 CA로 서명된 leaf cert으로 생성한다.
# CA가 운영용(사내 CA 서명)이면 자동 재생성을 건너뛴다.
# ════════════════════════════════════════════
CERTS_DIR_VAR=""   # 함수가 BASE_DIR을 참조하기 전에 set
CA_INSTALL_NAME="llm-access-gateway-local-root-ca.crt"
LOCAL_CA_SUBJECT="/C=KR/O=PoC/CN=Local Dev Root CA"
DEV_CERT_REGENERATED=false

_cert_paths() {
  # Nginx가 실제로 로딩하는 경로 (운영 cert이 그대로 놓이는 자리; dev 모드에서는 dev/* 로의 symlink)
  CERTS_DIR="${BASE_DIR}/nginx/certs"
  NGINX_SRV_CRT="${CERTS_DIR}/server.crt"
  NGINX_SRV_KEY="${CERTS_DIR}/server.key"

  # 로컬 dev 산출물 — 운영 cert과 헷갈리지 않도록 별도 subdir로 격리
  DEV_DIR="${CERTS_DIR}/dev"
  CA_KEY="${DEV_DIR}/local-root-ca.key"
  CA_CRT="${DEV_DIR}/local-root-ca.crt"
  CA_SERIAL="${DEV_DIR}/local-root-ca.srl"
  SRV_KEY="${DEV_DIR}/server.key"
  SRV_CRT="${DEV_DIR}/server.crt"
  SRV_CSR="${DEV_DIR}/server.csr"
  SRV_CNF="${DEV_DIR}/server-openssl.cnf"
  SRV_EXT="${DEV_DIR}/server-ext.cnf"
}

# 외부(사내 CA 등) 인증서가 배치된 상태인지 판정.
# 운영용 cert 신호: nginx/certs/server.crt 가 **일반 파일** (symlink 아님) 이고
# 그 cert의 issuer가 "Local Dev Root CA" 가 아닐 때.
# (dev 모드에서는 server.crt 가 dev/server.crt 로의 symlink — 명확한 시각적 구분)
is_production_cert() {
  _cert_paths
  [[ -f "$NGINX_SRV_CRT" ]] || return 1

  # symlink이면 dev 모드로 분류 (production이라고 판정하지 않음)
  if [[ -L "$NGINX_SRV_CRT" ]]; then
    return 1
  fi

  # 일반 파일이면 issuer 추가 검사
  local issuer
  issuer=$(openssl x509 -in "$NGINX_SRV_CRT" -noout -issuer 2>/dev/null || true)
  if echo "$issuer" | grep -q "Local Dev Root CA"; then
    return 1   # 우연히 일반 파일이지만 우리 CA가 서명한 것 → dev로 분류
  fi
  return 0     # 외부에서 배치한 cert
}

# 개발용 dev cert chain 전체가 codex 호환 형태로 valid한지 검증
is_valid_dev_cert() {
  _cert_paths
  [[ -f "$CA_KEY" && -f "$CA_CRT" && -f "$SRV_KEY" && -f "$SRV_CRT" ]] || return 1
  # nginx가 들이밀 cert이 dev/* 를 가리키는 symlink인지 검사
  [[ -L "$NGINX_SRV_CRT" && -L "$NGINX_SRV_KEY" ]] || return 1
  # symlink 대상이 dev/ 안의 파일인지
  local crt_target key_target
  crt_target=$(readlink "$NGINX_SRV_CRT" 2>/dev/null || true)
  key_target=$(readlink "$NGINX_SRV_KEY" 2>/dev/null || true)
  [[ "$crt_target" == "dev/server.crt" && "$key_target" == "dev/server.key" ]] || return 1

  local text
  text=$(openssl x509 -in "$SRV_CRT" -noout -text 2>/dev/null) || return 1

  echo "$text" | grep -q "DNS:localhost" || return 1
  echo "$text" | grep -q "IP Address:127.0.0.1" || return 1
  echo "$text" | grep -A 1 "X509v3 Basic Constraints" | grep -q "CA:FALSE" || return 1
  echo "$text" | grep -A 1 "Extended Key Usage" | grep -q "TLS Web Server Authentication" || return 1

  # issuer가 우리 CA여야 함
  local srv_issuer ca_subject
  srv_issuer=$(openssl x509 -in "$SRV_CRT" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
  ca_subject=$(openssl x509 -in "$CA_CRT" -noout -subject 2>/dev/null | sed 's/^subject=//')
  [[ "$srv_issuer" == "$ca_subject" ]] || return 1

  return 0
}

generate_dev_tls_cert() {
  _cert_paths
  info "Generating Local Dev Root CA + server cert (codex-friendly chain) into ${DEV_DIR}/"
  mkdir -p "$DEV_DIR"

  # 기존 dev/ 산출물 초기화 (남은 시리얼/csr 등 정리)
  rm -f "$CA_KEY" "$CA_CRT" "$CA_SERIAL" "$SRV_KEY" "$SRV_CRT" "$SRV_CSR" "$SRV_CNF" "$SRV_EXT"

  # 1) Root CA key + self-signed CA cert (5y)
  openssl genrsa -out "$CA_KEY" 4096 2>/dev/null
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 1825 \
    -out "$CA_CRT" \
    -subj "$LOCAL_CA_SUBJECT" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    2>/dev/null

  # 2) 서버 key
  openssl genrsa -out "$SRV_KEY" 2048 2>/dev/null

  # 3) CSR config
  cat > "$SRV_CNF" <<'EOF'
[req]
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
C  = KR
O  = PoC
CN = localhost
EOF

  # 4) CSR
  openssl req -new -key "$SRV_KEY" -out "$SRV_CSR" -config "$SRV_CNF" 2>/dev/null

  # 5) 서명용 extensions (CA:FALSE + serverAuth + SAN)
  cat > "$SRV_EXT" <<'EOF'
basicConstraints     = critical,CA:FALSE
keyUsage             = critical,digitalSignature,keyEncipherment
extendedKeyUsage     = serverAuth
subjectAltName       = DNS:localhost,IP:127.0.0.1
EOF

  # 6) CA로 서명 (825d — modern TLS 정책의 leaf 상한)
  openssl x509 -req -in "$SRV_CSR" \
    -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$SRV_CRT" -days 825 -sha256 \
    -extfile "$SRV_EXT" 2>/dev/null

  chmod 600 "$CA_KEY" "$SRV_KEY"
  chmod 644 "$CA_CRT" "$SRV_CRT"

  # 7) Nginx가 실제로 들이밀 cert을 dev/* 로의 *상대 symlink*로 노출.
  #    → 호스트와 컨테이너(/etc/nginx/certs/) 양쪽에서 정상 resolve
  #    → ls -la nginx/certs/ 에서 dev 모드임이 한눈에 보임
  #    → 운영 cert으로 교체 시 사용자가 그냥 symlink를 덮어쓰면 됨
  ( cd "$CERTS_DIR" && rm -f server.crt server.key \
      && ln -s dev/server.crt server.crt \
      && ln -s dev/server.key server.key )

  DEV_CERT_REGENERATED=true
  ok "Dev TLS chain generated"
  ok "  Local Dev Root CA: ${CA_CRT}  (this is what goes into OS trust store)"
  ok "  Dev leaf cert:     ${SRV_CRT}  (SAN: DNS:localhost, IP:127.0.0.1; CA:FALSE)"
  ok "  Nginx symlinks:    ${NGINX_SRV_CRT} -> dev/server.crt"
  ok "                     ${NGINX_SRV_KEY} -> dev/server.key"
}

_print_manual_ca_install() {
  warn "Manual install (run once):"
  warn "  sudo cp ${CA_CRT} /usr/local/share/ca-certificates/${CA_INSTALL_NAME}"
  warn "  sudo update-ca-certificates"
  warn "그 외 OS는 docs/local-dev-codex-tls.md 참조."
}

install_local_root_ca_if_possible() {
  _cert_paths
  local auto="${AUTO_INSTALL_DEV_CA:-true}"

  if [[ "$auto" != "true" ]]; then
    info "AUTO_INSTALL_DEV_CA=false; skipping OS trust store install"
    _print_manual_ca_install
    return 0
  fi

  if [[ ! -d /usr/local/share/ca-certificates ]] || ! command -v update-ca-certificates >/dev/null; then
    warn "Not a Debian/Ubuntu trust store layout; skipping auto install"
    _print_manual_ca_install
    return 0
  fi

  local target="/usr/local/share/ca-certificates/${CA_INSTALL_NAME}"

  if [[ -f "$target" ]] && cmp -s "$target" "$CA_CRT" 2>/dev/null; then
    ok "Local dev Root CA already in OS trust store (${target})"
    return 0
  fi

  info "Installing Local Dev Root CA to OS trust store (sudo required)..."
  info "  ⓘ Cancel with Ctrl-C if you prefer manual install — start.sh will continue regardless."

  if sudo cp "$CA_CRT" "$target" 2>/dev/null \
     && sudo update-ca-certificates >/dev/null 2>&1; then
    ok "Local Dev Root CA installed at ${target}"
  else
    warn "sudo install failed or cancelled — start.sh continues."
    _print_manual_ca_install
  fi
}

ensure_dev_tls_cert() {
  _cert_paths

  # USE_EXISTING_TLS_CERT=true 면 무조건 보존 (운영 cert 케이스)
  if [[ "${USE_EXISTING_TLS_CERT:-false}" == "true" ]]; then
    if [[ -f "$SRV_CRT" && -f "$SRV_KEY" ]]; then
      ok "USE_EXISTING_TLS_CERT=true — preserving existing TLS files (no dev cert generation)"
      return 0
    fi
    warn "USE_EXISTING_TLS_CERT=true but cert files missing; falling back to dev cert generation"
  fi

  # 사내 CA 발급된 cert이면 자동 재생성 금지
  if is_production_cert; then
    ok "Existing TLS certificate detected (issuer != Local Dev Root CA)"
    ok "  Skipping dev cert generation — managed externally"
    return 0
  fi

  if is_valid_dev_cert; then
    ok "Local dev TLS chain is valid"
  else
    [[ -f "$SRV_CRT" ]] && info "Existing dev TLS chain incomplete or invalid — regenerating"
    generate_dev_tls_cert
  fi

  install_local_root_ca_if_possible
}

# ════════════════════════════════════════════
# Phase 0: Pre-flight
# ════════════════════════════════════════════
phase_preflight() {
  bold "[Phase 0] Pre-flight checks"

  for cmd in docker curl openssl python3; do
    command -v "$cmd" >/dev/null || err "Missing required command: ${cmd}"
  done

  if ! docker compose version >/dev/null 2>&1; then
    err "docker compose not available"
  fi

  if ! docker info >/dev/null 2>&1; then
    err "Docker daemon is not running. Start it (e.g., 'sudo service docker start' or Docker Desktop)."
  fi

  ok "All required tools available, Docker daemon reachable"
}

# ════════════════════════════════════════════
# Phase 1: Bootstrap (first-run setup)
# ════════════════════════════════════════════
phase_bootstrap() {
  bold "[Phase 1] Bootstrap"

  # Directories
  mkdir -p \
    "${BASE_DIR}/openbao/data" \
    "${BASE_DIR}/openbao/logs" \
    "${BASE_DIR}/openbao/config" \
    "${BASE_DIR}/nginx/certs" \
    "${BASE_DIR}/litellm" \
    "${BASE_DIR}/scripts" \
    "${BASE_DIR}/tests" \
    "${BASE_DIR}/secrets"

  # secrets/ 는 chmod 700 (런타임 시크릿 — AppRole 자격증명, OpenAI 키 렌더 파일)
  chmod 700 "${BASE_DIR}/secrets" 2>/dev/null || true

  # OpenBao 컨테이너는 uid 999로 동작하므로 호스트의 data/logs를 쓸 수 있어야 함.
  # 기존 디렉토리가 호스트 사용자 소유로 만들어져 있으면 OpenBao가 init/audit 파일을 못 씀.
  chmod 777 "${BASE_DIR}/openbao/data" 2>/dev/null || true
  chmod 777 "${BASE_DIR}/openbao/logs" 2>/dev/null || true

  # docker-compose의 env_file 검증을 위해 placeholder 생성 (02-load-secrets가 이후 갱신)
  if [[ ! -f "${BASE_DIR}/secrets/litellm-secrets.env" ]]; then
    touch "${BASE_DIR}/secrets/litellm-secrets.env"
    chmod 600 "${BASE_DIR}/secrets/litellm-secrets.env"
  fi

  # 호스트 IP 감지 (신규/기존 .env 모두에서 사용)
  local host_ip
  host_ip=$(detect_host_ip)

  # .env 생성/갱신
  if [[ ! -f "$ENV_FILE" ]]; then
    info "Creating .env from .env.example with random secrets..."
    info "Detected host IP for PROXY_BASE_URL: ${host_ip}"

    cp "${BASE_DIR}/.env.example" "$ENV_FILE"
    local mk pp
    mk="sk-master-$(openssl rand -hex 24)"
    pp="$(openssl rand -hex 16)"
    HOST_IP="$host_ip" MK="$mk" PP="$pp" ENV_FILE="$ENV_FILE" python3 - <<'PY'
import os, re
p = os.environ["ENV_FILE"]
url = f"https://{os.environ['HOST_IP']}"
s = open(p).read()
s = re.sub(r'^LITELLM_MASTER_KEY=.*$', f"LITELLM_MASTER_KEY={os.environ['MK']}", s, flags=re.M)
s = re.sub(r'^POSTGRES_PASSWORD=.*$', f"POSTGRES_PASSWORD={os.environ['PP']}", s, flags=re.M)
s = re.sub(r'^PROXY_BASE_URL=.*$', f"PROXY_BASE_URL={url}", s, flags=re.M)
open(p, 'w').write(s)
PY
    chmod 600 "$ENV_FILE"
    ok ".env created (chmod 600, PROXY_BASE_URL=https://${host_ip})"
  else
    # 기존 .env 보존 — 단, PROXY_BASE_URL이 기본값(localhost)이면 감지된 IP로 갱신
    local current_url
    current_url=$(grep "^PROXY_BASE_URL=" "$ENV_FILE" | cut -d= -f2- || true)
    if [[ "$current_url" == "https://localhost" || -z "$current_url" ]] && [[ "$host_ip" != "localhost" ]]; then
      info "Updating PROXY_BASE_URL in existing .env: ${current_url:-<empty>} → https://${host_ip}"
      HOST_IP="$host_ip" ENV_FILE="$ENV_FILE" python3 - <<'PY'
import os, re
p = os.environ["ENV_FILE"]
url = f"https://{os.environ['HOST_IP']}"
s = open(p).read()
if re.search(r'^PROXY_BASE_URL=.*$', s, flags=re.M):
    s = re.sub(r'^PROXY_BASE_URL=.*$', f"PROXY_BASE_URL={url}", s, flags=re.M)
else:
    if not s.endswith("\n"):
        s += "\n"
    s += f"PROXY_BASE_URL={url}\n"
open(p, 'w').write(s)
PY
      ok ".env PROXY_BASE_URL updated to https://${host_ip}"
    else
      ok ".env exists (PROXY_BASE_URL=${current_url})"
    fi
  fi

  # TLS dev certs — Local Root CA + Root-signed leaf for https://localhost
  # (단일 self-signed cert은 codex의 rustls가 CaUsedAsEndEntity로 거부함)
  ensure_dev_tls_cert

  # Make all scripts executable
  chmod +x "${BASE_DIR}/scripts/"*.sh "${BASE_DIR}/tests/"*.sh "${BASE_DIR}"/*.sh 2>/dev/null || true

  # config/users.conf — 사용자/키 매핑 설정 파일
  if [[ ! -f "${BASE_DIR}/config/users.conf" ]]; then
    info "Creating config/users.conf from example (placeholder values)..."
    mkdir -p "${BASE_DIR}/config"
    cp "${BASE_DIR}/config/users.conf.example" "${BASE_DIR}/config/users.conf"
    chmod 600 "${BASE_DIR}/config/users.conf"
    warn "Edit config/users.conf with real OpenAI keys + passwords, then re-run ./start.sh"
    warn "(현재는 placeholder 값으로 진행됩니다 — 실 OpenAI 호출은 401 반환)"
  else
    chmod 600 "${BASE_DIR}/config/users.conf"
    ok "config/users.conf exists"
  fi
}

# ════════════════════════════════════════════
# Phase 2: Start OpenBao only
# ════════════════════════════════════════════
phase_start_openbao() {
  bold "[Phase 2] Start OpenBao"

  cd "$BASE_DIR"
  docker compose up -d openbao
  info "Waiting for OpenBao to become reachable..."
  for i in $(seq 1 30); do
    if docker exec openbao bao status -address=http://127.0.0.1:8200 >/dev/null 2>&1; then
      break
    fi
    if docker exec openbao bao status -address=http://127.0.0.1:8200 2>&1 | grep -qi "sealed\|initialized"; then
      break
    fi
    sleep 1
  done
  ok "OpenBao container running"
}

# ════════════════════════════════════════════
# Phase 3 & 4: Init OpenBao + Load secrets
# ════════════════════════════════════════════
phase_init_secrets() {
  bold "[Phase 3] Initialize OpenBao + Unseal + Enable KV"
  bash "${BASE_DIR}/scripts/01-init-openbao.sh"

  bold "[Phase 4] Load user OpenAI keys (placeholders)"
  bash "${BASE_DIR}/scripts/02-load-secrets.sh"
}

# ════════════════════════════════════════════
# Phase 4b: Ensure pg_hba.conf allows trust auth for internal network
# 신규 init은 POSTGRES_HOST_AUTH_METHOD=trust로 처리되지만,
# 기존 데이터 볼륨이 있으면 pg_hba.conf가 옛 scram-sha-256 그대로라
# .env의 비밀번호와 mismatch가 발생한다. 이를 매번 idempotent하게 정렬한다.
# 안전성: postgres 포트는 호스트에 노출되지 않으므로 docker 내부 트래픽 한정.
# ════════════════════════════════════════════
phase_align_postgres_password() {
  bold "[Phase 4b] Ensure PostgreSQL accepts internal trust auth"

  cd "$BASE_DIR"
  docker compose up -d postgres >/dev/null

  info "Waiting for PostgreSQL to accept connections..."
  for i in $(seq 1 30); do
    if docker exec litellm-db pg_isready -U litellm >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  # pg_hba.conf 상태 확인
  if docker exec litellm-db grep -qE '^host[ \t]+all[ \t]+all[ \t]+all[ \t]+trust' \
       /var/lib/postgresql/data/pg_hba.conf 2>/dev/null; then
    ok "pg_hba.conf already configured for trust auth"
    return 0
  fi

  info "Patching pg_hba.conf (replacing host scram-sha-256 with trust for internal network)..."
  if ! docker exec litellm-db sh -c '
    HBA=/var/lib/postgresql/data/pg_hba.conf
    sed -i -E "/^host[ \t]+all[ \t]+all[ \t]+all[ \t]+/d" "$HBA"
    echo "host all all all trust" >> "$HBA"
  ' >/dev/null 2>&1; then
    warn "Could not patch pg_hba.conf — run ./reset.sh if LiteLLM fails"
    return 0
  fi

  # postgres 설정 reload (실패 시 컨테이너 재시작)
  if docker exec -u postgres litellm-db pg_ctl reload -D /var/lib/postgresql/data \
       >/dev/null 2>&1; then
    ok "pg_hba.conf patched and postgres reloaded"
  else
    info "pg_ctl reload unavailable, restarting postgres container..."
    docker compose restart postgres >/dev/null
    for i in $(seq 1 30); do
      if docker exec litellm-db pg_isready -U litellm >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
    ok "postgres restarted with new pg_hba.conf"
  fi
}

# ════════════════════════════════════════════
# Phase 5: Start remaining services
# ════════════════════════════════════════════
phase_start_remaining() {
  bold "[Phase 5] Start PostgreSQL + LiteLLM + Nginx"

  cd "$BASE_DIR"

  # SSO 자동 감지 — .env에 GENERIC_CLIENT_ID 값이 비어있지 않으면 override 포함
  COMPOSE_FILES=("-f" "docker-compose.yml")
  if grep -E "^GENERIC_CLIENT_ID=.+" "$ENV_FILE" >/dev/null 2>&1; then
    COMPOSE_FILES+=("-f" "docker-compose.sso.yml")
    info "SSO config detected — including docker-compose.sso.yml"
    # 후속 docker compose 호출(force-recreate 등)에서도 같은 파일 세트를 쓰도록 export
    export COMPOSE_FILE="docker-compose.yml:docker-compose.sso.yml"
  fi

  docker compose "${COMPOSE_FILES[@]}" up -d postgres litellm nginx
  ok "Containers started"

  # 인증서가 이번 run에서 재생성됐으면 nginx는 옛 cert을 잡고 있을 수 있음 → 재시작
  if [[ "${DEV_CERT_REGENERATED:-false}" == "true" ]] \
     && docker ps --format '{{.Names}}' | grep -qx llm-nginx; then
    info "TLS cert regenerated — reloading nginx with new cert..."
    docker compose "${COMPOSE_FILES[@]}" restart nginx >/dev/null
    ok "nginx reloaded"
  fi

  bold "[Phase 5b] Wait for LiteLLM readiness"
  bash "${BASE_DIR}/scripts/04-health-check.sh"
}

# ════════════════════════════════════════════
# Phase 6: Register users
# ════════════════════════════════════════════
phase_register_users() {
  bold "[Phase 6] Register sample users + issue Virtual Keys"
  bash "${BASE_DIR}/scripts/03-register-users.sh"
}

# ════════════════════════════════════════════
# Phase 7: Run tests
# ════════════════════════════════════════════
phase_tests() {
  bold "[Phase 7] Verification tests"
  if bash "${BASE_DIR}/tests/test-all.sh"; then
    ok "All tests passed"
  else
    warn "Some tests failed — review output above"
    return 1
  fi
}

# ════════════════════════════════════════════
# Phase 8: Print summary
# ════════════════════════════════════════════
phase_summary() {
  local mk
  mk=$(grep "^LITELLM_MASTER_KEY=" "$ENV_FILE" | cut -d= -f2-)
  _cert_paths

  echo ""
  bold "════════════════════════════════════════════════════"
  bold " LLM Access Gateway is RUNNING"
  bold "════════════════════════════════════════════════════"
  echo ""
  echo "  Admin UI:        https://localhost/ui   (login: Master Key)"
  echo "  API base:        https://localhost/v1"
  echo "  Master Key:      ${mk}"
  echo ""
  echo "  TLS layout:      ${CERTS_DIR}/"
  echo "                     server.crt -> dev/server.crt  (dev mode symlink)"
  echo "                     server.key -> dev/server.key  (dev mode symlink)"
  echo "                     dev/local-root-ca.crt  ← register THIS in OS trust store"
  echo "                     dev/local-root-ca.key  (chmod 600)"
  echo "                     dev/server.{crt,key,csr}, dev/server-*.cnf"
  echo ""
  echo "  운영 cert으로 교체: ${NGINX_SRV_CRT} 와 ${NGINX_SRV_KEY} 를 사내 CA"
  echo "                    발급 파일로 덮어쓰면 됨 (symlink가 일반 파일로 바뀌고 dev/ 무시됨)"
  echo ""
  echo "  Virtual Keys:    ${BASE_DIR}/scripts/sample-keys.txt   (10 lines, DO NOT COMMIT)"
  echo ""
  echo "  ── Codex setup ─────────────────────────────────────"
  echo "    1) ~/.codex/config.toml:"
  echo "         model_provider  = \"openai\""
  echo "         openai_base_url = \"https://localhost/v1\""
  echo "         model           = \"user01-gpt-4o\""
  echo "         approval_mode   = \"suggest\""
  echo ""
  echo "    2) Use the Virtual Key (NOT a real OpenAI key):"
  echo "         export OPENAI_API_KEY=\$(grep '^alice@local ' scripts/sample-keys.txt | awk '{print \$4}')"
  echo ""
  echo "    3) When prompted, choose 'Provide your own API key' and paste the sk-... above."
  echo "       Do NOT use 'Sign in with ChatGPT' — it sends an eyJh... bearer that LiteLLM rejects"
  echo "       ('expected to start with sk-')."
  echo ""
  echo "    4) Run:"
  echo "         codex"
  echo ""
  echo "  ── If https://localhost still says UnknownIssuer ───"
  echo "    The Local Dev Root CA was not added to OS trust store automatically."
  echo "    Run once:"
  echo "         sudo cp ${CA_CRT} /usr/local/share/ca-certificates/${CA_INSTALL_NAME}"
  echo "         sudo update-ca-certificates"
  echo "    Other OSes: docs/local-dev-codex-tls.md"
  echo ""
  echo "  Stop:       ./stop.sh        Reset: ./reset.sh"
  echo "  Logs:       docker compose logs -f litellm"
  bold "════════════════════════════════════════════════════"
}

# ════════════════════════════════════════════
# Main
# ════════════════════════════════════════════
main() {
  bold ""
  bold "════════════════════════════════════════════════════"
  bold " LLM Access Gateway — start.sh"
  bold "════════════════════════════════════════════════════"

  phase_preflight
  phase_bootstrap
  phase_start_openbao
  phase_init_secrets
  phase_align_postgres_password
  phase_start_remaining
  phase_register_users

  TEST_RESULT=0
  phase_tests || TEST_RESULT=$?

  phase_summary

  exit $TEST_RESULT
}

main "$@"
