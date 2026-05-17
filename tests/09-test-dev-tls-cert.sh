#!/usr/bin/env bash
# 09 — 개발용 TLS chain 검증 (Codex/rustls 호환성)
#
# 새 파일 레이아웃:
#   nginx/certs/server.crt   →  symlink → dev/server.crt   (dev 모드)
#   nginx/certs/server.key   →  symlink → dev/server.key   (dev 모드)
#   nginx/certs/dev/local-root-ca.crt                       (OS trust 등록 대상)
#   nginx/certs/dev/server.crt                              (실제 leaf cert)
#
# 검증:
#   (a) nginx/certs/server.crt 가 dev/server.crt 로의 symlink
#   (b) dev/local-root-ca.crt + dev/server.crt 파일 존재
#   (c) dev/server.crt SAN 에 DNS:localhost, IP:127.0.0.1
#   (d) dev/server.crt Basic Constraints = CA:FALSE  (codex CaUsedAsEndEntity 방지)
#   (e) dev/server.crt EKU 에 TLS Web Server Authentication
#   (f) dev/server.crt issuer == dev/local-root-ca subject (leaf가 CA로 서명됨)
#   (g) [best-effort] curl -sf (no -k) 로 https://localhost 도달
set -uo pipefail
: "${BASE_DIR:?}"

CERTS_DIR="${BASE_DIR}/nginx/certs"
NGINX_SRV_CRT="${CERTS_DIR}/server.crt"
NGINX_SRV_KEY="${CERTS_DIR}/server.key"
DEV_DIR="${CERTS_DIR}/dev"
CA_CRT="${DEV_DIR}/local-root-ca.crt"
SRV_CRT="${DEV_DIR}/server.crt"

PASS=true

# Production cert이 배치된 상태면 dev 모드 검증을 skip (의도된 운영 환경)
if [[ -f "$NGINX_SRV_CRT" && ! -L "$NGINX_SRV_CRT" ]]; then
  ISSUER=$(openssl x509 -in "$NGINX_SRV_CRT" -noout -issuer 2>/dev/null || true)
  if ! echo "$ISSUER" | grep -q "Local Dev Root CA"; then
    echo "  ⊘ Production TLS cert detected (regular file, issuer != Local Dev Root CA)"
    echo "    Skipping dev TLS chain validation — this test only applies to dev mode."
    echo "    issuer: $ISSUER"
    exit 0
  fi
fi

# (a) symlink 검사 (dev 모드)
if [[ -L "$NGINX_SRV_CRT" ]] && [[ "$(readlink "$NGINX_SRV_CRT")" == "dev/server.crt" ]]; then
  echo "  ✓ nginx/certs/server.crt -> dev/server.crt (dev mode)"
else
  echo "  ✗ nginx/certs/server.crt is not a symlink to dev/server.crt"
  PASS=false
fi
if [[ -L "$NGINX_SRV_KEY" ]] && [[ "$(readlink "$NGINX_SRV_KEY")" == "dev/server.key" ]]; then
  echo "  ✓ nginx/certs/server.key -> dev/server.key (dev mode)"
else
  echo "  ✗ nginx/certs/server.key is not a symlink to dev/server.key"
  PASS=false
fi

[[ -f "$SRV_CRT" ]]    && echo "  ✓ dev/server.crt exists"        || { echo "  ✗ dev/server.crt missing";       PASS=false; }
[[ -f "$CA_CRT" ]]     && echo "  ✓ dev/local-root-ca.crt exists" || { echo "  ✗ dev/local-root-ca.crt missing"; PASS=false; }

if [[ -f "$SRV_CRT" && -f "$CA_CRT" ]]; then
  TEXT=$(openssl x509 -in "$SRV_CRT" -noout -text 2>/dev/null)

  echo "$TEXT" | grep -q "DNS:localhost"        && echo "  ✓ SAN: DNS:localhost"     || { echo "  ✗ SAN missing DNS:localhost";    PASS=false; }
  echo "$TEXT" | grep -q "IP Address:127.0.0.1" && echo "  ✓ SAN: IP:127.0.0.1"      || { echo "  ✗ SAN missing IP:127.0.0.1";     PASS=false; }

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

  SRV_ISSUER=$(openssl x509 -in "$SRV_CRT" -noout -issuer  2>/dev/null | sed 's/^issuer=//')
  CA_SUBJECT=$(openssl x509 -in "$CA_CRT"  -noout -subject 2>/dev/null | sed 's/^subject=//')
  if [[ "$SRV_ISSUER" == "$CA_SUBJECT" ]]; then
    echo "  ✓ dev/server.crt issuer == dev/local-root-ca subject (chain OK)"
  else
    echo "  ✗ dev/server.crt issuer ≠ dev/local-root-ca subject"
    echo "    server.crt issuer:    $SRV_ISSUER"
    echo "    local-root-ca subject: $CA_SUBJECT"
    PASS=false
  fi
fi

# (g) Best-effort: curl -sf 로 localhost HTTPS 도달 (-k 없이)
if curl -sf -o /dev/null --connect-timeout 3 "https://localhost/health/readiness" 2>/dev/null; then
  echo "  ✓ HTTPS https://localhost reachable without -k (CA trusted by OS)"
else
  echo "  ⚠ HTTPS https://localhost requires -k — CA not installed in OS trust store."
  echo "    Run once:  sudo cp ${CA_CRT} /usr/local/share/ca-certificates/llm-access-gateway-local-root-ca.crt && sudo update-ca-certificates"
  echo "    (informational; not a hard failure)"
fi

$PASS
