#!/usr/bin/env bash
# ──────────────────────────────────────────────
# OpenAI Key를 OpenBao에 적재하는 헬퍼 (관리자 전용)
#
# 사용법:
#   ./scripts/set-openai-key.sh <SLOT> <OPENAI_KEY>
#
# 예시:
#   ./scripts/set-openai-key.sh user01 sk-proj-AAAA...
#   ./scripts/set-openai-key.sh user03 'sk-proj-BBBB...'
#
# 또는 stdin으로 (셸 히스토리에 키가 남지 않도록):
#   ./scripts/set-openai-key.sh user01 -
#   sk-proj-AAAA...
#   <Ctrl-D>
#
# 동작:
#   1) OpenBao(secret/litellm/USERnn_OPENAI_KEY)에 새 값 기록
#   2) ./start.sh를 다시 실행하면 .env / LiteLLM 컨테이너로 자동 전파
#      (이미 LiteLLM 가동 중이라면: docker compose restart litellm)
# ──────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BASE_DIR="$( dirname "$SCRIPT_DIR" )"
INIT_KEYS_FILE="${BASE_DIR}/openbao/init-keys.json"
BAO_ADDR_INTERNAL="http://127.0.0.1:8200"

usage() {
  cat <<'USAGE' >&2
Usage: ./scripts/set-openai-key.sh <SLOT> <OPENAI_KEY|->

  SLOT         user01 ~ user10
  OPENAI_KEY   sk-proj-... (또는 '-' 로 stdin 입력)

Examples:
  ./scripts/set-openai-key.sh user01 sk-proj-AAAA...
  ./scripts/set-openai-key.sh user01 -    # then paste key, Ctrl-D
USAGE
  exit 2
}

[[ $# -eq 2 ]] || usage

SLOT="$1"
KEY_ARG="$2"

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
echo ""
echo "  반영 방법 (둘 중 하나):"
echo "    A) ./start.sh                          # 멱등 — 모든 슬롯을 .env에 재동기화 + LiteLLM 재기동"
echo "    B) ./scripts/02-load-secrets.sh \\"
echo "       && docker compose restart litellm   # 더 빠른 부분 갱신"
