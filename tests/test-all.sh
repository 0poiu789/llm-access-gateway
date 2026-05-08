#!/usr/bin/env bash
# ──────────────────────────────────────────────
# 전체 통합 테스트 러너
# ──────────────────────────────────────────────
set -uo pipefail

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
TESTS_DIR="${BASE_DIR}/tests"

export BASE_DIR
export ENV_FILE="${BASE_DIR}/.env"
export LITELLM_URL="${LITELLM_URL:-https://localhost}"

PASS=0
FAIL=0
FAILED_TESTS=()

run_test() {
  local name="$1"
  local script="$2"

  echo ""
  echo "─────────────────────────────────────────"
  echo " TEST: ${name}"
  echo "─────────────────────────────────────────"

  if bash "$script"; then
    echo "  ✅ PASS — ${name}"
    PASS=$((PASS + 1))
  else
    echo "  ❌ FAIL — ${name}"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$name")
  fi
}

run_test "01 — Health & TLS"           "${TESTS_DIR}/01-test-health.sh"
run_test "02 — Models exposed"         "${TESTS_DIR}/02-test-models.sh"
run_test "03 — Key generation + TTL"   "${TESTS_DIR}/03-test-key-generation.sh"
run_test "04 — User isolation"         "${TESTS_DIR}/04-test-isolation.sh"
run_test "05 — Vault integration"      "${TESTS_DIR}/05-test-vault-integration.sh"
run_test "06 — RBAC"                   "${TESTS_DIR}/06-test-rbac.sh"

echo ""
echo "═════════════════════════════════════════"
echo " RESULTS: ${PASS} passed, ${FAIL} failed"
echo "═════════════════════════════════════════"

if (( FAIL > 0 )); then
  echo " Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "   - ${t}"
  done
  exit 1
fi
