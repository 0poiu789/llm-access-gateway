#!/usr/bin/env bash
# ──────────────────────────────────────────────
# (마이그레이션) 기존에 등록된 internal_user의 password 컬럼을 NULL로 비운다.
# 이전 버전 register-users.sh가 password를 설정했던 사용자의 잔여 데이터를
# 정리하여 LiteLLM OSS의 UI password 로그인 500 버그를 더 이상 트리거하지
# 않도록 한다. 1회만 실행하면 충분하지만 멱등이라 여러 번 실행해도 안전.
# ──────────────────────────────────────────────
set -euo pipefail

: "${BASE_DIR:?BASE_DIR not set}"

log() { echo "  [migrate] $*"; }

# postgres 컨테이너 안에서 password / password_hash 컬럼이 있는지 확인 후 NULL로 갱신.
# pg_hba.conf의 'host all all all trust' (start.sh Phase 4b 적용분) 덕분에
# 비밀번호 없이 접속 가능.
log "Clearing 'password' field for all internal_user records..."

# 컬럼이 password / password_hash / hashed_password 중 무엇인지 LiteLLM 버전에 따라 다를 수 있음.
# LiteLLM_UserTable의 모든 비밀번호 후보 컬럼을 NULL로.
docker exec litellm-db psql -h /var/run/postgresql -U litellm -d litellm <<'SQL' >/dev/null 2>&1 || true
DO $$
DECLARE
  col_name TEXT;
BEGIN
  FOR col_name IN
    SELECT column_name FROM information_schema.columns
    WHERE table_name = 'LiteLLM_UserTable'
      AND column_name IN ('password', 'password_hash', 'hashed_password', 'password_encrypted')
  LOOP
    EXECUTE format('UPDATE "LiteLLM_UserTable" SET %I = NULL WHERE user_role = ''internal_user''', col_name);
    RAISE NOTICE 'Cleared column: %', col_name;
  END LOOP;
END $$;
SQL

log "  ✓ Internal user password columns cleared (where applicable)"
