#!/usr/bin/env bash
# ──────────────────────────────────────────────
# LiteLLM이 readiness 응답할 때까지 대기 (최대 120초)
# ──────────────────────────────────────────────
set -euo pipefail

LITELLM_URL="${LITELLM_URL:-https://localhost}"
MAX_WAIT=120
INTERVAL=2

log() { echo "  [health] $*"; }

elapsed=0
while (( elapsed < MAX_WAIT )); do
  if curl -sk -o /dev/null -w "%{http_code}" "${LITELLM_URL}/health/readiness" 2>/dev/null | grep -q "200"; then
    log "✓ LiteLLM ready (${elapsed}s)"
    exit 0
  fi
  sleep $INTERVAL
  elapsed=$((elapsed + INTERVAL))
  if (( elapsed % 10 == 0 )); then
    log "  ...still waiting (${elapsed}s/${MAX_WAIT}s)"
  fi
done

echo "  [health] ✗ LiteLLM did NOT become ready within ${MAX_WAIT}s" >&2
echo "  [health]   Check: docker compose logs litellm" >&2
exit 1
