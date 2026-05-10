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

  bold "[Phase 5b] Wait for LiteLLM readiness"
  bash "${BASE_DIR}/scripts/04-health-check.sh"
}

# ════════════════════════════════════════════
# Phase 6: Register users
# ════════════════════════════════════════════
phase_register_users() {
  bold "[Phase 6] Register sample users + issue Virtual Keys"
  bash "${BASE_DIR}/scripts/03-register-users.sh"

  # 마이그레이션 — 이전 버전이 설정한 internal user password 잔여물 정리
  bash "${BASE_DIR}/scripts/05-clear-user-passwords.sh" || true
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
  echo "    VKEY=\$(grep '^alice@local ' scripts/sample-keys.txt | awk '{print \$4}')"
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
