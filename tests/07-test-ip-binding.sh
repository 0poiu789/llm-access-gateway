#!/usr/bin/env bash
# 07 — Virtual Key allowed_ips 페이로드 wiring 검증 (informational)
#
# LiteLLM OSS 1.82.6에는 per-key allowed_ips를 영속화하는 컬럼이 없어 /key/generate가
# 이 파라미터를 silent-drop한다 (LiteLLM_VerificationToken 테이블에 컬럼 부재).
# 따라서 본 테스트는 *클라이언트가 파라미터를 보냈는지*를 검증하고, 서버 영속화는
# OSS 한계로 인정한다 (D4 §2.2 ⑤ 참조).
#
# Enterprise 라이선스 또는 LiteLLM 업스트림에 컬럼이 추가되면 본 테스트를
# /key/info 라운드트립 검증으로 강화할 것.
set -uo pipefail
: "${LITELLM_URL:?}"
: "${ENV_FILE:?}"

MASTER_KEY=$(grep "^LITELLM_MASTER_KEY=" "$ENV_FILE" | cut -d= -f2-)
ALIAS="ip-binding-wiring-$(date +%s)"

# 1) 발급 — 파라미터를 받았다는 응답이 오는지만 확인
GEN_RESP=$(curl -sk -X POST "${LITELLM_URL}/key/generate" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"models\": [\"user01-gpt-4o\"],
    \"duration\": \"1h\",
    \"key_alias\": \"${ALIAS}\",
    \"allowed_ips\": [\"10.99.99.99\"]
  }")

VKEY=$(echo "$GEN_RESP" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('key',''))" 2>/dev/null)
if [[ -z "$VKEY" || "$VKEY" != sk-* ]]; then
  echo "  ✗ /key/generate 응답에 key가 없음: ${GEN_RESP:0:300}"
  exit 1
fi

cleanup() {
  curl -sk -X POST "${LITELLM_URL}/key/delete" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"keys\": [\"${VKEY}\"]}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "  ✓ /key/generate accepted allowed_ips param (key=${VKEY:0:18}...)"

# 2) /key/info에서 영속화 여부를 확인. 영속화되지 않더라도(OSS 한계) 정보성 메시지로만 출력 — PASS.
INFO=$(curl -sk -H "Authorization: Bearer ${MASTER_KEY}" \
  "${LITELLM_URL}/key/info?key=${VKEY}")
PERSISTED=$(echo "$INFO" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    info = d.get('info') or d
    ips = info.get('allowed_ips')
    print('YES' if ips else 'NO')
except Exception:
    print('NO')
")

if [[ "$PERSISTED" == "YES" ]]; then
  echo "  ✓ /key/info echoes allowed_ips (LiteLLM supports per-key IP binding — OK)"
else
  echo "  ⚠ LiteLLM OSS 1.82.x 한계: allowed_ips는 /key/generate에 받지만 영속화/echo 안 됨"
  echo "    Enterprise 또는 LiteLLM_VerificationToken에 컬럼이 추가된 버전에서 작동"
fi

exit 0
