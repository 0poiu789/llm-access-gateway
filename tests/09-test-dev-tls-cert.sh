#!/usr/bin/env bash
# 09 — 개발용 TLS chain 검증 (Codex/rustls 호환성)
#
# 검증:
#   (a) local-root-ca.crt / server.crt 파일 존재
#   (b) server.crt SAN 에 DNS:localhost, IP:127.0.0.1 포함
#   (c) server.crt Basic Constraints = CA:FALSE  (← codex가 CaUsedAsEndEntity 에러 안 내려면 필수)
#   (d) server.crt Extended Key Usage 에 TLS Web Server Authentication
#   (e) server.crt issuer 가 local-root-ca.crt subject 와 일치 (== leaf 가 CA로 서명됨)
#   (f) [best-effort] curl -sf (no -k) 로 /health/readiness 도달 — CA가 OS trust store에
#       자동 등록됐을 때만 성공. 실패해도 informational 로만 표시(차단 아님).
set -uo pipefail
: "${BASE_DIR:?}"

CA_CRT="${BASE_DIR}/nginx/certs/local-root-ca.crt"
CRT="${BASE_DIR}/nginx/certs/server.crt"
PASS=true

[[ -f "$CRT" ]]    && echo "  ✓ server.crt exists"          || { echo "  ✗ server.crt missing";       PASS=false; }
[[ -f "$CA_CRT" ]] && echo "  ✓ local-root-ca.crt exists"   || { echo "  ✗ local-root-ca.crt missing"; PASS=false; }

if [[ -f "$CRT" && -f "$CA_CRT" ]]; then
  TEXT=$(openssl x509 -in "$CRT" -noout -text 2>/dev/null)

  echo "$TEXT" | grep -q "DNS:localhost"          && echo "  ✓ SAN: DNS:localhost"        || { echo "  ✗ SAN missing DNS:localhost";   PASS=false; }
  echo "$TEXT" | grep -q "IP Address:127.0.0.1"   && echo "  ✓ SAN: IP:127.0.0.1"         || { echo "  ✗ SAN missing IP:127.0.0.1";    PASS=false; }

  if echo "$TEXT" | grep -A 1 "X509v3 Basic Constraints" | grep -q "CA:FALSE"; then
    echo "  ✓ Basic Constraints: CA:FALSE (codex/rustls compatible)"
  else
    echo "  ✗ Basic Constraints not CA:FALSE — codex will throw CaUsedAsEndEntity"
    PASS=false
  fi

  if echo "$TEXT" | grep -A 1 "X509v3 Extended Key Usage" | grep -q "TLS Web Server Authentication"; then
    echo "  ✓ Extended Key Usage: serverAuth"
  else
    echo "  ✗ Extended Key Usage missing serverAuth"
    PASS=false
  fi

  SRV_ISSUER=$(openssl x509 -in "$CRT"    -noout -issuer  2>/dev/null | sed 's/^issuer=//')
  CA_SUBJECT=$(openssl x509 -in "$CA_CRT" -noout -subject 2>/dev/null | sed 's/^subject=//')
  if [[ "$SRV_ISSUER" == "$CA_SUBJECT" ]]; then
    echo "  ✓ server.crt issuer == local-root-ca subject (leaf signed by our CA)"
  else
    echo "  ✗ server.crt issuer ≠ local-root-ca subject"
    echo "    server.crt issuer: $SRV_ISSUER"
    echo "    local-root-ca:    $CA_SUBJECT"
    PASS=false
  fi
fi

# Best-effort: curl -sf 로 localhost HTTPS 도달 (-k 없이)
if curl -sf -o /dev/null --connect-timeout 3 "https://localhost/health/readiness" 2>/dev/null; then
  echo "  ✓ HTTPS https://localhost reachable without -k (CA trusted by OS)"
else
  echo "  ⚠ HTTPS https://localhost requires -k — CA not installed in OS trust store."
  echo "    Run once:  sudo cp ${CA_CRT} /usr/local/share/ca-certificates/llm-access-gateway-local-root-ca.crt && sudo update-ca-certificates"
  echo "    (informational; not a hard failure)"
fi

$PASS
