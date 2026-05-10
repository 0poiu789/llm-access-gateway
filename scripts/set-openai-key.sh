#!/usr/bin/env bash
# ──────────────────────────────────────────────
# OpenAI Key를 OpenBao에 적재하는 헬퍼 (관리자 전용)
#
# 사용법:
#   ./scripts/set-openai-key.sh <SLOT> <OPENAI_KEY>           # 인자
#   ./scripts/set-openai-key.sh <SLOT> -                       # stdin (히스토리 회피)
#
# 옵션:
#   --no-reload   적재 후 자동 재기동을 생략 (기본은 02-load-secrets.sh + restart 자동 수행)
#
# 동작:
#   1) OpenBao에 KV write (root token; init-keys.json에서 직접 읽음)
#   2) (기본) 02-load-secrets.sh로 secrets/litellm-secrets.env 갱신
#   3) (기본) docker compose up -d --force-recreate litellm 으로 새 env 반영
# ──────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR="$( dirname "$SCRIPT_DIR" )"
INIT_KEYS_FILE="${BASE_DIR}/openbao/init-keys.json"
ENV_FILE="${BASE_DIR}/.env"
BAO_ADDR_INTERNAL="http://127.0.0.1:8200"

usage() {
  cat <<'USAGE' >&2
Usage: ./scripts/set-openai-key.sh <SLOT> <OPENAI_KEY|-> [--no-reload]

  SLOT         user01 ~ user10
  OPENAI_KEY   sk-proj-... (또는 '-' 로 stdin 입력)
  --no-reload  적재만 하고 자동 reload(02-load-secrets.sh + LiteLLM 재기동) 생략

Examples:
  ./scripts/set-openai-key.sh user01 sk-proj-AAAA...
  ./scripts/set-openai-key.sh user01 -                   # then paste key, Ctrl-D
  ./scripts/set-openai-key.sh user01 sk-... --no-reload  # 일괄 적재 후 한 번에 reload
USAGE
  exit 2
}

[[ $# -ge 2 ]] || usage

SLOT="$1"
KEY_ARG="$2"
RELOAD=true
if [[ "${3:-}" == "--no-reload" ]]; then
  RELOAD=false
fi

if [[ ! "$SLOT" =~ ^user[0-9]{2}$ ]]; then
  echo "✗ SLOT은 user01~user10 형식이어야 합니다 (받은 값: '$SLOT')" >&2
  exit 1
fi

if [[ "$KEY_ARG" == "-" ]]; then
  echo "  Paste OpenAI key, then press Ctrl-D:" >&2
  KEY="$(cat)"
  KEY="${KEY//$'\n'/}"
else
  KEY="$KEY_ARG"
fi

if [[ -z "$KEY" || ! "$KEY" =~ ^sk- ]]; then
  echo "✗ Key 값이 비어있거나 'sk-'로 시작하지 않습니다." >&2
  exit 1
fi

if [[ ! -f "$INIT_KEYS_FILE" ]]; then
  echo "✗ ${INIT_KEYS_FILE} 가 없습니다. 먼저 ./start.sh를 1회 실행하여 OpenBao를 초기화하세요." >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx openbao; then
  echo "✗ openbao 컨테이너가 실행 중이 아닙니다. ./start.sh 또는 docker compose up -d openbao" >&2
  exit 1
fi

ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${INIT_KEYS_FILE}'))['root_token'])")

NN="${SLOT#user}"
VAR_NAME="USER${NN}_OPENAI_KEY"

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put -address="$BAO_ADDR_INTERNAL" \
  "secret/litellm/${VAR_NAME}" \
  key="$KEY" >/dev/null

echo "✓ OpenBao 'secret/litellm/${VAR_NAME}' 갱신됨"

if $RELOAD; then
  echo "  Reloading: secrets render + LiteLLM restart..."
  BASE_DIR="$BASE_DIR" bash "${SCRIPT_DIR}/02-load-secrets.sh"
  ( cd "$BASE_DIR" && docker compose up -d --force-recreate litellm >/dev/null 2>&1 )
  echo "✓ LiteLLM 재기동 완료 (새 키 반영)"
else
  echo ""
  echo "  --no-reload 지정됨. 반영 명령:"
  echo "    bash scripts/02-load-secrets.sh"
  echo "    docker compose up -d --force-recreate litellm"
fi
