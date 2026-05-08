#!/usr/bin/env bash
# Health, TLS, redirect 검증
set -uo pipefail
: "${LITELLM_URL:?}"

PASS=true

# 1) HTTPS /health 200
CODE=$(curl -sk -o /dev/null -w "%{http_code}" "${LITELLM_URL}/health/liveliness")
if [[ "$CODE" == "200" ]]; then
  echo "  ✓ HTTPS /health/liveliness → 200"
else
  echo "  ✗ HTTPS /health/liveliness → ${CODE} (expected 200)"
  PASS=false
fi

# 2) HTTP → HTTPS 301 redirect
HTTP_BASE="${LITELLM_URL/https/http}"
HTTP_BASE="${HTTP_BASE/:443/}"
REDIRECT_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${HTTP_BASE}/" 2>/dev/null || echo "fail")
LOCATION=$(curl -sI "${HTTP_BASE}/" 2>/dev/null | grep -i "^location:" | tr -d '\r' | head -1 || echo "")
if [[ "$REDIRECT_CODE" == "301" ]] && [[ "$LOCATION" == *"https://"* ]]; then
  echo "  ✓ HTTP → HTTPS 301 redirect"
else
  echo "  ✗ HTTP redirect (code=${REDIRECT_CODE}, location='${LOCATION}')"
  PASS=false
fi

# 3) TLS 인증서 정보 표시 (정보용, fail 처리하지 않음)
if SUBJECT=$(echo | openssl s_client -connect "${LITELLM_URL#https://}:443" -servername localhost 2>/dev/null | openssl x509 -noout -subject 2>/dev/null); then
  echo "  · TLS subject: ${SUBJECT}"
fi

$PASS
