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
    "${BASE_DIR}/tests"

  # .env
  if [[ ! -f "$ENV_FILE" ]]; then
    info "Creating .env from .env.example with random secrets..."

    # 호스트 IP 자동 감지 (PROXY_BASE_URL 기본값으로 사용)
    local host_ip
    host_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)
    if [[ -z "$host_ip" ]]; then
      host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    if [[ -z "$host_ip" || "$host_ip" == "127.0.0.1" ]]; then
      host_ip="localhost"
    fi
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
    export ENV_REGENERATED=true
  else
    ok ".env exists"
    export ENV_REGENERATED=false
  fi

  # TLS self-signed cert
  if [[ ! -f "${BASE_DIR}/nginx/certs/server.crt" ]]; then
    info "Generating self-signed TLS certificate..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "${BASE_DIR}/nginx/certs/server.key" \
      -out "${BASE_DIR}/nginx/certs/server.crt" \
      -subj "/C=KR/ST=Seoul/L=Seoul/O=PoC/CN=llm-gateway.local" \
      2>/dev/null
    chmod 600 "${BASE_DIR}/nginx/certs/server.key"
    ok "TLS certificate generated (1y validity)"
  else
    ok "TLS certificate exists"
  fi

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
# Phase 4b: Align PostgreSQL password if .env was regenerated
# ════════════════════════════════════════════
phase_align_postgres_password() {
  if [[ "${ENV_REGENERATED:-false}" != "true" ]]; then
    return 0
  fi

  bold "[Phase 4b] Align PostgreSQL password (.env was regenerated)"

  cd "$BASE_DIR"
  docker compose up -d postgres >/dev/null

  info "Waiting for PostgreSQL to accept connections..."
  for i in $(seq 1 30); do
    if docker exec litellm-db pg_isready -U postgres >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  # 첫 init이라 'litellm' DB가 아직 없으면 align 불필요 (compose가 새 비밀번호로 생성함)
  if ! docker exec litellm-db psql -U litellm -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='litellm'" 2>/dev/null | grep -q "^1$"; then
    info "PostgreSQL not yet initialized — fresh init will use new password"
    return 0
  fi

  # 기존 데이터 볼륨에 옛 비밀번호가 저장되어 있다면 ALTER USER로 동기화
  local new_pw
  new_pw=$(grep "^POSTGRES_PASSWORD=" "$ENV_FILE" | cut -d= -f2-)
  if docker exec litellm-db psql -U litellm -d litellm \
       -c "ALTER USER litellm WITH PASSWORD '${new_pw}'" >/dev/null 2>&1; then
    ok "PostgreSQL password aligned with new .env"
  else
    warn "Could not ALTER USER on existing PostgreSQL data"
    warn "If LiteLLM fails to start, run './reset.sh' to wipe and re-init"
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

  echo ""
  bold "════════════════════════════════════════════════════"
  bold " LLM Access Gateway is RUNNING"
  bold "════════════════════════════════════════════════════"
  echo ""
  echo "  Admin UI:    https://localhost/ui   (use Master Key to log in)"
  echo "  API base:    https://localhost/v1"
  echo "  Master Key:  ${mk}"
  echo ""
  echo "  10 sample Virtual Keys saved to:"
  echo "    ${BASE_DIR}/scripts/sample-keys.txt"
  echo ""
  echo "  Quick test (alice's key, alice = user01):"
  echo "    VKEY=\$(grep '^alice@local ' scripts/sample-keys.txt | awk '{print \$3}')"
  echo "    curl -sk https://localhost/v1/models -H \"Authorization: Bearer \$VKEY\" | python3 -m json.tool"
  echo ""
  echo "  Self-signed TLS — use 'curl -k' or accept browser warning"
  echo ""
  echo "  Stop:        ./stop.sh"
  echo "  Reset (wipe data): ./reset.sh"
  echo "  Logs:        docker compose logs -f litellm"
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
