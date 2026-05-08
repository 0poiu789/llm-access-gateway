#!/usr/bin/env bash
# 컨테이너 재기동 후 OpenBao를 unseal하는 스탠드얼론 스크립트
# (start.sh 실행 시에는 자동 처리되므로 보통 직접 호출할 필요 없음)
set -euo pipefail

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
INIT_KEYS="${BASE_DIR}/openbao/init-keys.json"

if [[ ! -f "$INIT_KEYS" ]]; then
  echo "ERROR: ${INIT_KEYS} not found." >&2
  exit 1
fi

for i in 0 1 2; do
  KEY=$(python3 -c "import json; print(json.load(open('${INIT_KEYS}'))['unseal_keys_b64'][$i])")
  docker exec openbao bao operator unseal -address=http://127.0.0.1:8200 "$KEY" >/dev/null
done
echo "[$(date)] OpenBao unsealed"
