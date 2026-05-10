#!/usr/bin/env bash
# 전체 정지 + 모든 데이터 삭제 (위험!)
set -euo pipefail
cd "$( dirname "${BASH_SOURCE[0]}" )"

read -p "Wipe ALL data (OpenBao secrets, PostgreSQL, init keys)? [yes/N] " ans
if [[ "$ans" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

docker compose down -v 2>/dev/null || true

# OpenBao data/logs는 컨테이너 내부에서 uid 999로 소유 → 호스트 사용자가 못 지움.
# 일시 컨테이너로 wipe (alpine 또는 openbao 이미지 재사용).
if [[ -d openbao/data || -d openbao/logs ]]; then
  docker run --rm \
    -v "$(pwd)/openbao/data:/openbao/data" \
    -v "$(pwd)/openbao/logs:/openbao/logs" \
    alpine sh -c 'rm -rf /openbao/data/* /openbao/data/.* /openbao/logs/* /openbao/logs/.* 2>/dev/null || true' \
    >/dev/null 2>&1 || true
fi

rm -f openbao/init-keys.json 2>/dev/null || true
rm -f scripts/sample-keys.txt 2>/dev/null || true
rm -f .env 2>/dev/null || true
rm -f nginx/certs/server.* 2>/dev/null || true
rm -rf secrets 2>/dev/null || true

echo "✓ All data wiped. Run ./start.sh to start fresh."
