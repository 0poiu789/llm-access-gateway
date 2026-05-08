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
rm -rf openbao/data/* openbao/logs/* openbao/init-keys.json 2>/dev/null || true
rm -f scripts/sample-keys.txt 2>/dev/null || true
rm -f .env 2>/dev/null || true
rm -f nginx/certs/server.* 2>/dev/null || true
echo "✓ All data wiped. Run ./start.sh to start fresh."
