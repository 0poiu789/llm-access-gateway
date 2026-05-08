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
    cp "${BASE_DIR}/.env.example" "$ENV_FILE"
    local mk pp
    mk="sk-master-$(openssl rand -hex 24)"
    pp="$(openssl rand -hex 16)"
    python3 -c "
import re
p = '$ENV_FILE'
mk = '$mk'
pp = '$pp'
s = open(p).read()
s = re.sub(r'^LITELLM_MASTER_KEY=.*$', f'LITELLM_MASTER_KEY={mk}', s, flags=re.M)
s = re.sub(r'^POSTGRES_PASSWORD=.*$', f'POSTGRES_PASSWORD={pp}', s, flags=re.M)
open(p, 'w').write(s)
"
    chmod 600 "$ENV_FILE"
    ok ".env created (chmod 600)"
  else
    ok ".env exists"
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
# Phase 5: Start remaining services
# ════════════════════════════════════════════
phase_start_remaining() {
  bold "[Phase 5] Start PostgreSQL + LiteLLM + Nginx"

  cd "$BASE_DIR"
  docker compose up -d postgres litellm nginx
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
  phase_start_remaining
  phase_register_users

  TEST_RESULT=0
  phase_tests || TEST_RESULT=$?

  phase_summary

  exit $TEST_RESULT
}

main "$@"
