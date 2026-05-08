#!/usr/bin/env bash
# 전체 서비스 정지 (데이터 보존)
set -euo pipefail
cd "$( dirname "${BASH_SOURCE[0]}" )"
docker compose down
echo "✓ Stopped (data preserved). Restart with ./start.sh"
