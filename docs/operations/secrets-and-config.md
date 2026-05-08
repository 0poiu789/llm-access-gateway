# 비밀 파일 및 환경 설정 가이드

> 사내 환경으로 본 저장소를 머지/클론한 후 **어떤 파일을 만들고 어떻게 채워야 하는지**를 한 곳에 정리한 문서.

## 1. 왜 이 문서가 필요한가

`.env`, TLS 키, OpenBao Unseal Key, Virtual Key 목록 등 **유출되면 시스템 전체가 위험해지는 파일은 git에 커밋하지 않는다**(.gitignore로 제외). 따라서 다른 환경에서 클론하면 이 파일들이 존재하지 않는다.

본 문서는 그 부재 파일들을 다음 두 부류로 나누어 각각의 처리 방법을 설명한다.

- **자동 생성 파일** — `./start.sh` 실행만으로 채워짐. 사용자 작업 불필요.
- **수동 작성/교체 필요 항목** — PoC 기본값을 사내 실값으로 바꿔야 하는 항목.

---

## 2. 비밀 파일 일람

| 경로 | 분류 | 생성 시점 | 사용자 작업 | 비고 |
|------|------|----------|------------|------|
| `.env` | 자동 + 수정 가능 | `start.sh` Phase 1 | 운영 시 일부 항목 교체 | 랜덤 Master Key/PG 비밀번호 자동 생성 |
| `nginx/certs/server.crt` | 자동 + 교체 권장 | `start.sh` Phase 1 | PoC 그대로, 운영 시 사내 CA로 교체 | 자체서명 1년 유효 |
| `nginx/certs/server.key` | 자동 | `start.sh` Phase 1 | 위와 동일 | chmod 600 |
| `openbao/init-keys.json` | 자동 | `start.sh` Phase 3 | **오프라인 백업 후 서버에서 삭제 필수** | Unseal 키 5개 + Root Token. 분실 시 OpenBao 복구 불가 |
| `openbao/data/` | 자동 | OpenBao 컨테이너 | 백업 권장 | 시크릿 영속 저장소 |
| `openbao/logs/` | 자동 | OpenBao 컨테이너 | (감사 로그 활성화 시) 백업 권장 | 운영 시 audit 로그 활성화 권장 |
| `postgres-data` (Docker volume) | 자동 | PostgreSQL 컨테이너 | 백업 필수 | 사용자/Key/Spend/Prompt 로그 |
| `scripts/sample-keys.txt` | 자동 | `start.sh` Phase 6 | 사용자에게 안전한 채널로 전달 | 발급된 Virtual Key 10개 |
| OpenBao 시크릿: `secret/litellm/USER01..10_OPENAI_KEY` | 자동 적재(placeholder) | `start.sh` Phase 4 | **실제 OpenAI Key로 교체 필수** | 본 문서 §4.1 참조 |
| `.env`의 `GENERIC_*` 변수 | 빈 값(자동) | `start.sh` Phase 1 | SSO 활성화 시 채움 | 본 문서 §4.2 참조 |

---

## 3. 자동 생성 파일 (사용자 작업 불필요)

### 3.1 `.env`

`./start.sh` 최초 실행 시 `.env.example`을 복사한 뒤 다음 두 값을 랜덤 문자열로 자동 채운다:

```
LITELLM_MASTER_KEY=sk-master-<openssl rand -hex 24의 결과>
POSTGRES_PASSWORD=<openssl rand -hex 16의 결과>
```

`OPENBAO_ROOT_TOKEN`은 Phase 3 (OpenBao 초기화) 후 자동으로 채워진다.

권한은 `chmod 600`으로 설정되어 소유자만 읽을 수 있다.

### 3.2 `nginx/certs/server.{crt,key}`

`./start.sh`가 다음 명령으로 자체서명 인증서를 발급한다 (1년 유효).

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout nginx/certs/server.key \
  -out nginx/certs/server.crt \
  -subj "/C=KR/ST=Seoul/L=Seoul/O=PoC/CN=llm-gateway.local"
```

브라우저/CLI에서 인증서 경고가 나오므로 `curl -k` 또는 브라우저 예외 추가 필요. **운영 환경에서는 §4.3에 따라 사내 CA 또는 Let's Encrypt 인증서로 교체할 것.**

### 3.3 `openbao/init-keys.json`

`./start.sh` Phase 3에서 OpenBao를 처음 초기화할 때 다음 명령으로 생성된다:

```bash
docker exec openbao bao operator init -key-shares=5 -key-threshold=3 -format=json
```

내용 구조:

```json
{
  "unseal_keys_b64": ["...", "...", "...", "...", "..."],
  "unseal_keys_hex": ["...", "...", "...", "...", "..."],
  "unseal_threshold": 3,
  "recovery_keys_b64": [],
  "root_token": "s.xxxxxxxxxxxxx"
}
```

> ⚠️ **중요**: 이 파일이 유출되면 OpenBao의 모든 시크릿이 노출된다. 동시에 분실하면 OpenBao 복구가 불가능하다. 운영 시에는:
> 1. 다른 안전한 곳(오프라인 USB, 사내 비밀 관리 도구 등)에 백업
> 2. 5개 Unseal 키를 5명의 다른 책임자에게 분산 보관 (Shamir Secret Sharing 원리)
> 3. 서버에서는 삭제 (또는 권한을 더 엄격히)
> 4. 컨테이너 재기동 시 `./openbao/unseal.sh`가 이 파일을 참조하므로, 삭제했다면 unseal 시점에만 임시로 복구

### 3.4 `openbao/data/`, `openbao/logs/`, `postgres-data`

컨테이너 런타임 데이터. 자동 생성. 운영 환경에서는 정기 백업 권장.

```bash
# OpenBao 데이터 백업 예시
tar czf openbao-backup-$(date +%Y%m%d).tar.gz openbao/data/

# PostgreSQL 백업 예시
docker exec litellm-db pg_dump -U litellm litellm > litellm-db-$(date +%Y%m%d).sql
```

### 3.5 `scripts/sample-keys.txt`

`./start.sh` Phase 6 (`03-register-users.sh`)이 사용자별 Virtual Key를 발급한 뒤 자동 작성한다.

내용 형식:

```
# Generated 2026-05-08T15:30:00+09:00 — DO NOT COMMIT
# Format: <email> <slot> <virtual_key>

alice@local user01 sk-vk-abcdef...
bob@local   user02 sk-vk-ghijkl...
...
```

각 사용자에게 본인 Key만 안전한 채널(이메일/사내 메신저 다이렉트)로 전달한다. 24h 후 만료되므로 다음 날에는 사용자가 UI에서 직접 Regenerate한다.

---

## 4. 수동 작성/교체 필요 항목

PoC 기본값으로 시작해도 동작은 하지만, **실제 사내 운영을 위해서는 다음 4가지를 교체해야 한다.**

### 4.1 사내 OpenAI API Key 10개 적재 (필수)

`./start.sh`는 `sk-proj-poc-userNN-placeholder-replace-with-real-key` 형태의 placeholder 키를 적재한다. 이 상태에서는 OpenAI API 호출이 401로 실패한다 (인증/라우팅 검증은 영향 없음).

**교체 절차:**

```bash
# 1. OpenBao Root Token 확보
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('openbao/init-keys.json'))['root_token'])")

# 2. 사용자별 실제 키로 교체 (10명)
docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put -address=http://127.0.0.1:8200 \
  secret/litellm/USER01_OPENAI_KEY key="sk-proj-실제alice의키"

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put -address=http://127.0.0.1:8200 \
  secret/litellm/USER02_OPENAI_KEY key="sk-proj-실제bob의키"

# ... user03 ~ user10도 동일하게

# 3. LiteLLM 재시작 (시크릿 캐시 무효화)
docker compose restart litellm

# 4. 검증
curl -sk https://localhost/v1/chat/completions \
  -H "Authorization: Bearer <alice의 Virtual Key>" \
  -H "Content-Type: application/json" \
  -d '{"model": "user01-gpt-4o", "messages": [{"role":"user","content":"hello"}]}'
# → OpenAI 정상 응답이어야 정상
```

**일괄 처리 스크립트 예시 (`scripts/load-real-keys.sh` — 직접 작성 필요):**

```bash
#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${BASE_DIR}/openbao/init-keys.json'))['root_token'])")

# 사내 환경에서만 사용. 절대 git에 커밋하지 말 것.
declare -A REAL_KEYS=(
  ["USER01_OPENAI_KEY"]="sk-proj-실제alice키"
  ["USER02_OPENAI_KEY"]="sk-proj-실제bob키"
  ["USER03_OPENAI_KEY"]="sk-proj-실제carol키"
  # ... 10명
)

for KEY_NAME in "${!REAL_KEYS[@]}"; do
  docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
    bao kv put -address=http://127.0.0.1:8200 \
    "secret/litellm/${KEY_NAME}" \
    key="${REAL_KEYS[$KEY_NAME]}" >/dev/null
  echo "  ✓ ${KEY_NAME} updated"
done

docker compose restart litellm
echo "  ✓ LiteLLM restarted"
```

> ⚠️ 이 스크립트는 **실 키를 평문으로 포함**하므로 절대 git에 커밋하지 말 것. `.gitignore`에 `scripts/load-real-keys.sh` 추가 권장.

### 4.2 사내 IdP SSO 활성화 (선택, 운영 시 필수)

PoC 기본값에서는 SSO가 비활성. Master Key 또는 발급된 Virtual Key로 인증한다. SSO를 켜려면 `.env`의 다음 항목을 사내 IdP에서 발급받은 값으로 채운다.

```bash
# .env 편집
GENERIC_CLIENT_ID=<IdP에서 발급받은 OIDC 클라이언트 ID>
GENERIC_CLIENT_SECRET=<IdP 클라이언트 시크릿>
GENERIC_AUTHORIZATION_ENDPOINT=https://idp.사내도메인/oauth/authorize
GENERIC_TOKEN_ENDPOINT=https://idp.사내도메인/oauth/token
GENERIC_USERINFO_ENDPOINT=https://idp.사내도메인/oauth/userinfo

# 클레임 매핑은 IdP 토큰 구조에 맞게 조정 (기본값으로 대부분 OK)
GENERIC_USER_ID_JWT_FIELD=sub
GENERIC_USER_EMAIL_JWT_FIELD=email
GENERIC_USER_FIRST_NAME_JWT_FIELD=given_name
GENERIC_USER_LAST_NAME_JWT_FIELD=family_name
GENERIC_USER_ROLE_JWT_FIELD=groups

# 도메인 화이트리스트 (외부 도메인 차단)
ALLOWED_USER_EMAIL_DOMAINS=사내도메인.com
```

**IdP에서 사전 준비할 것:**
- OIDC 클라이언트 등록 (Redirect URI: `https://llm-gateway.사내도메인/sso/callback`)
- 그룹: `llm-gateway-users`, `llm-gateway-admins` 생성 후 사용자 등록
- id_token에 `groups` 클레임 포함되도록 매핑

상세 절차는 [D2 §6, §9](../design/D2-system-requirements.md) 참조.

설정 후 `docker compose restart litellm`으로 적용.

### 4.3 운영용 TLS 인증서 적용 (운영 시 필수)

자체서명 인증서는 브라우저 경고가 나오고 보안적으로도 약함. 운영 환경에서는 다음 중 하나로 교체:

**옵션 A — 사내 CA 발급 인증서:**

```bash
# 사내 CA가 발급한 인증서로 교체
cp /path/to/사내CA발급/server.crt nginx/certs/server.crt
cp /path/to/사내CA발급/server.key nginx/certs/server.key
chmod 600 nginx/certs/server.key
docker compose restart nginx
```

**옵션 B — Let's Encrypt (외부 도메인 노출 가능 시):**

```bash
# certbot으로 발급 (예: certbot --nginx 또는 standalone)
certbot certonly --standalone -d llm-gateway.사내도메인.com
cp /etc/letsencrypt/live/llm-gateway.사내도메인.com/fullchain.pem nginx/certs/server.crt
cp /etc/letsencrypt/live/llm-gateway.사내도메인.com/privkey.pem  nginx/certs/server.key
chmod 600 nginx/certs/server.key
docker compose restart nginx
```

`.env`의 `PROXY_BASE_URL`도 실제 도메인으로 변경:

```
PROXY_BASE_URL=https://llm-gateway.사내도메인.com
```

### 4.4 사용자 매핑 변경 (alice/bob → 실제 사내 인원)

`scripts/03-register-users.sh`의 `USERS` 배열이 PoC 샘플 인원(alice@local 등)을 등록한다. 사내 실 인원으로 교체:

```bash
# scripts/03-register-users.sh 편집 — USERS 배열 수정
USERS=(
  "honggildong@사내도메인.com user01 홍길동"
  "kimchulsoo@사내도메인.com   user02 김철수"
  # ... 10명까지
)
ADMIN_EMAIL="admin@사내도메인.com"
```

수정 후 `./start.sh` 재실행. 멱등이라 안전 (이미 등록된 사용자는 건너뛰고, 새 사용자만 추가).

기존 PoC 샘플 사용자(alice~jack)를 제거하려면 LiteLLM UI 또는 API로 삭제:

```bash
MASTER_KEY=$(grep "^LITELLM_MASTER_KEY=" .env | cut -d= -f2-)
for EMAIL in alice@local bob@local carol@local dave@local eve@local \
             frank@local grace@local henry@local ivy@local jack@local; do
  curl -sk -X POST "https://localhost/user/delete" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"user_emails\": [\"${EMAIL}\"]}"
done
```

---

## 5. 사내 환경 첫 배포 체크리스트

본 저장소를 사내 서버에 클론한 후 다음 순서로 진행:

```
[1] 저장소 클론 + Docker 환경 확인
    □ git clone <저장소>
    □ cd llm-access-gateway
    □ docker info 정상 응답

[2] 매핑 변경 (선택, 사용자 이름이 alice~jack이어도 무방)
    □ scripts/03-register-users.sh 의 USERS 배열을 사내 실 인원 이메일로 수정

[3] 첫 부트스트랩
    □ ./start.sh 실행
    □ Phase 7 검증 테스트 6개 모두 통과 확인
    □ scripts/sample-keys.txt 생성 확인

[4] OpenBao Unseal 키 백업 (보안 필수)
    □ openbao/init-keys.json 을 안전한 오프라인 매체에 복사
    □ Unseal 키 5개를 5명의 다른 책임자에게 분산 보관
    □ 서버의 init-keys.json 권한 점검 (600)

[5] 실 OpenAI API Key 적재 (§4.1)
    □ 각 사용자별 실 키 10개를 OpenBao에 적재
    □ docker compose restart litellm
    □ 사용자 1명으로 실 API 호출 → OpenAI 정상 응답 확인

[6] TLS 운영 인증서 교체 (§4.3)
    □ 사내 CA 또는 Let's Encrypt 인증서로 교체
    □ .env 의 PROXY_BASE_URL 을 실 도메인으로 변경
    □ docker compose restart nginx

[7] SSO 활성화 (선택, 운영 시 권장, §4.2)
    □ IdP에 OIDC 클라이언트 등록 + 그룹 생성
    □ .env 의 GENERIC_* 항목 채움
    □ ALLOWED_USER_EMAIL_DOMAINS 사내 도메인으로 설정
    □ docker compose restart litellm
    □ 브라우저로 SSO 로그인 검증

[8] 방화벽/네트워크 점검
    □ 80, 443만 외부 노출 (4000, 5432, 8200 차단 확인)
    □ Admin 계정 IP 제한 (선택)

[9] 사용자에게 배포 안내
    □ 각 사용자에게 본인 Virtual Key를 안전한 채널로 전달
    □ 또는 SSO URL 안내 (사용자가 직접 발급)
    □ Codex CLI 설정 가이드 안내 (D2 §18)

[10] 일일 운영 시작
    □ OpenBao Sealed 상태 모니터링
    □ Spend 대시보드 일일 확인
    □ 24h Key 만료 사용자 응대 절차 마련
```

---

## 6. 백업 및 복원

### 6.1 정기 백업 대상

| 대상 | 빈도 | 방법 |
|------|------|------|
| `openbao/init-keys.json` | 1회 (변경 없음) | 오프라인 매체 |
| `openbao/data/` | 매일 | `tar czf` |
| PostgreSQL DB | 매일 | `pg_dump` |
| `.env` | 변경 시 | 안전한 비밀 관리 도구 (Vault 등) |
| `nginx/certs/` | 인증서 갱신 시 | 안전한 매체 |

### 6.2 복원 시나리오 (서버 이전 등)

```bash
# 1. 새 서버에 저장소 클론
git clone <저장소>
cd llm-access-gateway

# 2. 백업 파일 복원
cp /backup/init-keys.json openbao/init-keys.json
chmod 600 openbao/init-keys.json
tar xzf /backup/openbao-data-YYYYMMDD.tar.gz -C openbao/

# 3. .env 복원 또는 재생성
cp /backup/.env .env
chmod 600 .env

# 4. TLS 인증서 복원
cp /backup/server.{crt,key} nginx/certs/

# 5. 기동 (start.sh가 멱등이므로 기존 데이터 보존)
./start.sh

# 6. PostgreSQL 복원 (필요 시)
docker exec -i litellm-db psql -U litellm litellm < /backup/litellm-db.sql
docker compose restart litellm
```

---

## 7. 비밀 노출 시 즉시 대응

### 7.1 `init-keys.json` 또는 OpenBao Root Token 노출

```bash
# 1. 새 Root Token 발급 (기존 무효화)
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('openbao/init-keys.json'))['root_token'])")
NEW_TOKEN=$(docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao token create -policy=root -format=json | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")

# 2. 기존 Root Token revoke
docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao bao token revoke -self

# 3. .env 업데이트
sed -i "s|^OPENBAO_ROOT_TOKEN=.*|OPENBAO_ROOT_TOKEN=${NEW_TOKEN}|" .env
docker compose restart litellm

# 4. 모든 사용자 OpenAI Key를 OpenAI Console에서 회전 (§4.1로 새 키 적재)
```

### 7.2 `.env`의 `LITELLM_MASTER_KEY` 노출

```bash
# 새 Master Key 발급
NEW_MK="sk-master-$(openssl rand -hex 24)"
sed -i "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=${NEW_MK}|" .env
docker compose restart litellm

# 기존 Virtual Key는 유효 — 필요 시 일괄 차단 후 재발급
```

### 7.3 사용자 Virtual Key 유출

```bash
MASTER_KEY=$(grep "^LITELLM_MASTER_KEY=" .env | cut -d= -f2-)

# 유출된 Key 즉시 차단
curl -sk -X POST "https://localhost/key/delete" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"keys": ["sk-vk-유출된키"]}'

# 사용자에게 UI 재로그인하여 새 Key 발급 안내
# 24h TTL 정책 덕분에 자연 만료까지의 노출 시간은 최대 24h
```

### 7.4 OpenAI 실 API Key 유출

OpenAI Console에서 즉시 회전 → §4.1로 새 키를 OpenBao에 적재 → `docker compose restart litellm`.

---

## 8. 자주 묻는 질문

**Q. `start.sh`를 두 번 실행하면 비밀 파일이 덮어써지는가?**

아니다. 모든 자동 생성 단계는 멱등(idempotent)으로 작성되었다. 이미 존재하는 `.env`, `init-keys.json`, TLS 인증서는 재사용된다. 기존 OpenBao 시크릿도 보존된다.

**Q. `reset.sh`는 무엇을 삭제하는가?**

`reset.sh`는 `.env`, `init-keys.json`, OpenBao 데이터, PostgreSQL 볼륨, TLS 인증서, `sample-keys.txt`를 모두 삭제하고 컨테이너를 내린다. **백업 없이 실행하면 모든 데이터를 잃는다.** 사용자 확인을 받은 뒤에만 동작.

**Q. SSO 없이 사용자가 본인의 Virtual Key를 어떻게 받는가?**

PoC에서는 관리자가 `scripts/sample-keys.txt`에서 해당 사용자의 Key를 안전한 채널(이메일/사내 메신저)로 전달. SSO 활성화 후에는 사용자가 직접 UI 로그인하여 발급/조회.

**Q. 사용자가 11명 이상 필요하면?**

D2 §19.1 "신규 사용자 추가" 절차를 따른다:
1. OpenBao에 새 OpenAI Key 추가 (`secret/litellm/USER11_OPENAI_KEY`)
2. `litellm/config.yaml`에 모델 항목 2개 추가 (`user11-gpt-4o`, `user11-o3-mini`)
3. `docker compose restart litellm`
4. `/user/new` API로 사용자 등록

**Q. `.gitignore`에 추가해야 할 파일이 더 있는가?**

다음을 만들면 추가:
- `scripts/load-real-keys.sh` (실 OpenAI Key 적재 스크립트)
- `backup/` (로컬 백업 디렉토리)
- `*.sql` (DB 덤프)
- `*.tar.gz` (백업 압축 파일)
