# 비밀 파일 및 환경 설정 가이드

> 사내 환경으로 본 저장소를 머지/클론한 후 **어떤 파일을 만들고 어떻게 채워야 하는지**를 한 곳에 정리한 문서.

## 1. 왜 이 문서가 필요한가

`.env`, TLS 키, OpenBao Unseal Key, Virtual Key 목록 등 **유출되면 시스템 전체가 위험해지는 파일은 git에 커밋하지 않는다**(.gitignore로 제외). 따라서 다른 환경에서 클론하면 이 파일들이 존재하지 않는다.

본 문서는 그 부재 파일들을 다음 두 부류로 나누어 각각의 처리 방법을 설명한다.

- **자동 생성 파일** — `./start.sh` 실행만으로 채워짐. 사용자 작업 불필요.
- **수동 작성/교체 필요 항목** — PoC 기본값을 사내 실값으로 바꿔야 하는 항목.

---

## 2. 비밀 파일 일람

> **두 source of truth로 분리**:
> - **OpenAI Key** → **OpenBao** (`secret/litellm/USERnn_OPENAI_KEY`). 관리자가 OpenAI 콘솔에서 발급 직후 `./scripts/set-openai-key.sh`로 직접 적재. 평문 파일(`config/users.conf`, `.env`)에 두지 않음.
> - **사용자 메타데이터(slot/email/name/allowed_ips)** → **`config/users.conf`** (4-field). 관리자가 편집.
>
> **인증/접근 분리**:
> - **root token** — `openbao/init-keys.json`에만 존재. 부트스트랩 + 키 쓰기(`set-openai-key.sh`)에만 사용.
> - **AppRole `litellm`** — read-only 정책. 일상 운영(02-load-secrets.sh)이 사용. 자격증명은 `secrets/openbao-approle.env` (chmod 600).
>
> **내부 흐름**: OpenBao → AppRole read → `secrets/litellm-secrets.env`(캐시, 자동 미러링) → LiteLLM 컨테이너 OS env. LiteLLM OSS는 OpenBao 직접 연동 미지원(Enterprise 전용)으로 캐시 단계가 남는다. 관리자가 손으로 만지는 source는 **OpenBao 한 곳**(키)과 **`config/users.conf`**(메타데이터) 두 곳뿐.

| 경로 | 분류 | 생성 시점 | 사용자 작업 | 비고 |
|------|------|----------|------------|------|
| **OpenBao 시크릿: `secret/litellm/USER01..10_OPENAI_KEY`** | **OpenAI Key의 SSOT** | `start.sh` Phase 4 (placeholder만 자동) | **`./scripts/set-openai-key.sh userNN sk-proj-...` 로 실 키 적재** | 저장 시 암호화. 회전 시 여기만 갱신 |
| **`config/users.conf`** | **사용자 메타데이터 SSOT** | `start.sh` Phase 1 (example 복사) | **slot/email/name/allowed_ips 편집** | .gitignore + chmod 600 |
| `.env` | 자동 + 일부 수정 가능 | `start.sh` Phase 1 | 운영 시 일부 항목 교체(`PROXY_BASE_URL`, `GENERIC_*`) | 랜덤 Master Key/PG 비밀번호. **OpenAI Key/Root Token 모두 없음** |
| `.env`의 `GENERIC_*` 변수 | 빈 값(자동) | `start.sh` Phase 1 | SSO 활성화 시 채움 | 본 문서 §4.2 참조 |
| **`secrets/openbao-approle.env`** | **AppRole 자격증명** (자동) | `start.sh` Phase 3 | (미작업; 무효화 시 `rm` 후 `start.sh`) | role-id + secret-id. chmod 600 |
| **`secrets/litellm-secrets.env`** | **OpenAI Key 캐시** (자동 렌더) | `start.sh` Phase 4 | **직접 편집 금지 — OpenBao에서 갱신** | AppRole로 자동 미러. chmod 600 |
| `nginx/certs/server.crt` | 자동 (dev 모드: dev/server.crt 로의 symlink) | `start.sh` Phase 1 | 운영 시 사내 CA 발급 cert으로 일반 파일 교체 | codex(rustls) 호환을 위해 CA 서명된 leaf |
| `nginx/certs/server.key` | 자동 (dev 모드: dev/server.key 로의 symlink) | `start.sh` Phase 1 | 위와 동일 | chmod 600 |
| `nginx/certs/dev/` | 자동 (로컬 dev 산출물 전용) | `start.sh` Phase 1 | 미작업 (운영 cert과 분리되어 격리됨) | Local Root CA, leaf, CSR, config |
| `openbao/init-keys.json` | 자동 | `start.sh` Phase 3 | **오프라인 백업 후 서버에서 삭제 필수** | Unseal 키 5개 + Root Token. 분실 시 OpenBao 복구 불가 |
| `openbao/data/` | 자동 | OpenBao 컨테이너 | 백업 권장 | 시크릿 영속 저장소 (master) |
| `openbao/logs/audit.log` | 자동 (Phase 3 활성화) | OpenBao 컨테이너 | 보존 정책 수립 (회전 / SIEM 연동) | 모든 KV read/write JSON 라인 — HMAC된 토큰 accessor만 |
| `postgres-data` (Docker volume) | 자동 | PostgreSQL 컨테이너 | 백업 필수 | 사용자/Key/Spend/Prompt 로그 |
| `scripts/sample-keys.txt` | 자동 | `start.sh` Phase 6 | 사용자에게 안전한 채널로 전달 | 발급된 Virtual Key (allowed_ips 주석 포함) |

---

## 3. 자동 생성 파일 (사용자 작업 불필요)

### 3.1 `.env`

`./start.sh` 최초 실행 시 `.env.example`을 복사한 뒤 다음 두 값을 랜덤 문자열로 자동 채운다:

```
LITELLM_MASTER_KEY=sk-master-<openssl rand -hex 24의 결과>
POSTGRES_PASSWORD=<openssl rand -hex 16의 결과>
```

> **주의**: `.env`에는 OpenAI Key가 **없다**. `USER01..10_OPENAI_KEY`는 `secrets/litellm-secrets.env`(별도 파일)로 분리되어 02-load-secrets.sh가 OpenBao→AppRole 경로로 자동 렌더링한다. `OPENBAO_ROOT_TOKEN`도 `.env`에 두지 않으며, 쓰기가 필요한 도구는 `openbao/init-keys.json`에서 직접 읽는다.

권한은 `chmod 600`으로 설정되어 소유자만 읽을 수 있다.

### 3.1.1 `secrets/openbao-approle.env`

`./start.sh` Phase 3가 OpenBao를 초기화하면서 다음을 만든다:

- `litellm-readonly` 정책 — `secret/data/litellm/*` read만 허용
- AppRole `litellm` role — TTL 1h, max TTL 24h, secret_id_ttl=0(무한)
- 위 role의 `role-id`(안정) + `secret-id`(재발급) → `secrets/openbao-approle.env` (chmod 600)

02-load-secrets.sh는 이 자격증명으로 AppRole 로그인하여 단명 토큰을 받아 KV read만 수행한다. root token은 일상 운영에 사용되지 않는다.

### 3.1.2 `secrets/litellm-secrets.env`

`USER01_OPENAI_KEY` ~ `USER10_OPENAI_KEY` 10개를 담는 별도 env 파일. `./start.sh` 실행마다 02-load-secrets.sh가 AppRole로 OpenBao를 read하여 갱신한다. docker-compose의 `env_file` 디렉티브가 이 파일을 LiteLLM 컨테이너의 OS env로 주입하며, LiteLLM의 `api_key: "os.environ/USERnn_OPENAI_KEY"` 표기가 이를 읽는다. **이 파일은 직접 편집하지 말고 OpenBao에서 갱신할 것** (§4.1 참조). chmod 600, gitignore.

### 3.2 `nginx/certs/server.{crt,key}` + `nginx/certs/dev/`

`./start.sh` Phase 1의 `ensure_dev_tls_cert` 함수가 두 단계로 동작한다:

1. **Local Dev Root CA + 그 CA로 서명된 leaf** 를 `nginx/certs/dev/` 에 생성. leaf는 `CA:FALSE`, SAN=`DNS:localhost,IP:127.0.0.1`, EKU=`serverAuth` 로 codex(rustls) 호환.
2. `nginx/certs/server.{crt,key}` 를 `dev/server.{crt,key}` 로의 **relative symlink** 로 노출. Nginx는 항상 `nginx/certs/server.{crt,key}` 에서 cert을 로딩하므로 운영 cert 교체 시에도 위치는 동일.

레이아웃:
```
nginx/certs/
├── server.crt          → symlink → dev/server.crt   (dev 모드)  /  운영 cert (사내 CA)
├── server.key          → symlink → dev/server.key   (dev 모드)  /  운영 key
└── dev/                ← 로컬 dev 산출물 전용 (gitignored)
    ├── local-root-ca.{crt,key,srl}     ← .crt를 OS trust store에 등록
    └── server.{crt,key,csr}, server-*.cnf
```

`is_production_cert` 가 `server.crt` 의 symlink 여부 + issuer 로 dev/운영을 자동 판별. 운영 cert이 일반 파일로 놓여 있으면 dev 재생성을 건너뛴다.

브라우저/CLI에서 인증서 경고가 나오면 `dev/local-root-ca.crt` 를 OS trust store에 등록 (`./start.sh` 가 `AUTO_INSTALL_DEV_CA=true` 기본으로 자동 시도). 자세한 절차/대안 OS는 [`docs/local-dev-codex-tls.md`](../local-dev-codex-tls.md). **운영 환경에서는 §4.3에 따라 사내 CA 또는 Let's Encrypt 인증서로 교체**.

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

### 4.1 사내 OpenAI API Key 적재 — OpenBao 직접

OpenAI Key는 **OpenBao만이 source of truth**다. 평문 파일(`config/users.conf`, `.env`)에 적지 않는다.

**OpenAI 콘솔 측 권장 절차:**

1. Organization → API keys → 사용자별로 별도 Key 발급(slot과 1:1)
2. **IP 화이트리스트** — 게이트웨이(LiteLLM) 호스트의 outbound IP를 등록
3. 사용량 한도 / 알림 설정
4. 발급 직후 표시되는 Key 문자열은 마지막 노출 기회이므로 **즉시** 아래 적재 절차로 OpenBao에 넣고 콘솔 창을 닫는다.

**OpenBao 적재 (3가지 방법, 어느 것이든 OK):**

```bash
# (A) 헬퍼 스크립트 — 인자
./scripts/set-openai-key.sh user01 sk-proj-AAAA...

# (B) 헬퍼 스크립트 — stdin (셸 히스토리에 키 흔적을 남기지 않음)
./scripts/set-openai-key.sh user01 -
# 키 붙여넣기 후 Ctrl-D

# (C) bao CLI 직접
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('openbao/init-keys.json'))['root_token'])")
docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put -address=http://127.0.0.1:8200 \
  secret/litellm/USER01_OPENAI_KEY key="sk-proj-AAAA..."
```

**적재 후 반영:**

`set-openai-key.sh` (방법 A, B)는 **자동으로** 다음을 수행한다:

1. OpenBao에 KV write (root token, init-keys.json에서)
2. `02-load-secrets.sh` 실행 — AppRole로 read하여 `secrets/litellm-secrets.env` 갱신
3. `docker compose up -d --force-recreate litellm` — 새 env 반영

방법 C(`bao kv put` 직접) 사용 시에는 위 2-3단계를 직접 실행:

```bash
BASE_DIR=. bash scripts/02-load-secrets.sh
docker compose up -d --force-recreate litellm
```

또는 `./start.sh` 재실행(멱등 — 모든 단계 + Virtual Key 재발급).

> 💡 **`restart` vs `up -d --force-recreate`**: `docker compose restart litellm`은 컨테이너 프로세스만 재시작할 뿐 env 변수를 다시 읽지 않는다. `secrets/litellm-secrets.env`를 갱신했을 때는 `up -d --force-recreate`(또는 `./start.sh`)를 사용해야 새 값이 적용된다.

**검증:**

```bash
VKEY=$(grep '^alice@local ' scripts/sample-keys.txt | awk '{print $4}')
curl -sk -X POST https://<서버IP>/v1/chat/completions \
  -H "Authorization: Bearer ${VKEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"user01-gpt-4o","messages":[{"role":"user","content":"hi"}]}'
#  → 200 + OpenAI 정상 응답이면 OK
```

**Key 회전:**

OpenAI 콘솔에서 새 Key 발급 → `set-openai-key.sh userNN sk-proj-NEW...` → `./start.sh` → 콘솔에서 구 키 즉시 revoke.

**OpenBao 시크릿 보안:**

- 저장 시 암호화 (저장 시점에 OpenBao가 자체 키로 암호화)
- 접근 권한: 현재 PoC는 root token 단독 사용 — 운영 시 사용자별 정책/AppRole로 분리 권장
- `init-keys.json` 분실 시 OpenBao 영구 봉인. 오프라인 백업 필수 (§3.3)

### 4.2 사내 IdP SSO 활성화 (선택, 운영 시 필수)

PoC 기본값에서는 SSO가 비활성. Master Key 또는 발급된 Virtual Key로 인증한다.

> ⚠️ **LiteLLM OSS 제약**: `GENERIC_CLIENT_ID`, `MICROSOFT_CLIENT_ID`, `GOOGLE_CLIENT_ID` 중 하나라도 컨테이너 환경변수에 **set되어 있기만 하면 (빈 값이라도) Enterprise 라이선스를 요구**한다 (응답: 403 `premium_user`). 따라서 본 PoC는 이 변수들을 별도 override 파일 `docker-compose.sso.yml`에 분리하여, **SSO를 사용할 때만 해당 파일을 포함**시키는 구조로 설계되었다.

**활성화 절차:**

```bash
# 1. .env에 SSO 값 추가 (최초에는 .env에 GENERIC_* 라인이 없을 수 있으므로 추가)
cat >> .env << 'EOF'

# OIDC SSO
GENERIC_CLIENT_ID=<IdP에서 발급받은 OIDC 클라이언트 ID>
GENERIC_CLIENT_SECRET=<IdP 클라이언트 시크릿>
GENERIC_AUTHORIZATION_ENDPOINT=https://idp.사내도메인/oauth/authorize
GENERIC_TOKEN_ENDPOINT=https://idp.사내도메인/oauth/token
GENERIC_USERINFO_ENDPOINT=https://idp.사내도메인/oauth/userinfo

# 클레임 매핑 (IdP 토큰 구조에 맞게 조정. 기본값으로 대부분 OK)
GENERIC_USER_ID_JWT_FIELD=sub
GENERIC_USER_EMAIL_JWT_FIELD=email
GENERIC_USER_FIRST_NAME_JWT_FIELD=given_name
GENERIC_USER_LAST_NAME_JWT_FIELD=family_name
GENERIC_USER_ROLE_JWT_FIELD=groups

# 도메인 화이트리스트
ALLOWED_USER_EMAIL_DOMAINS=사내도메인.com
DEFAULT_USER_ROLES_LITELLM_SSO=internal_user_viewer
EOF

# 2. start.sh가 GENERIC_CLIENT_ID 값을 감지해 자동으로 docker-compose.sso.yml을 포함시킨다.
./start.sh
```

**수동으로 SSO를 다루려면** (start.sh를 거치지 않을 때):

```bash
# SSO 활성화 — 두 compose 파일을 함께 사용
docker compose -f docker-compose.yml -f docker-compose.sso.yml up -d --force-recreate litellm

# 또는 환경변수 한 번 export 후 일반 명령
export COMPOSE_FILE=docker-compose.yml:docker-compose.sso.yml
docker compose up -d --force-recreate litellm
```

**SSO 비활성화로 되돌리기:**

```bash
# .env에서 GENERIC_* 모두 제거
sed -i '/^GENERIC_/d; /^ALLOWED_USER_EMAIL_DOMAINS/d; /^DEFAULT_USER_ROLES_LITELLM_SSO/d' .env

# COMPOSE_FILE 환경변수 해제 후 재기동
unset COMPOSE_FILE
docker compose up -d --force-recreate litellm
```

**IdP에서 사전 준비할 것:**
- OIDC 클라이언트 등록 (Redirect URI: `https://llm-gateway.사내도메인/sso/callback`)
- 그룹: `llm-gateway-users`, `llm-gateway-admins` 생성 후 사용자 등록
- id_token에 `groups` 클레임 포함되도록 매핑

상세 절차는 [D2 §6, §9](../design/D2-system-requirements.md) 참조.

### 4.3 운영용 TLS 인증서 적용 (운영 시 필수)

`./start.sh`의 기본 dev 모드는 Local Dev Root CA + 그 CA로 서명한 leaf 를 만들지만, 운영 환경에서는 사내 CA 발급 cert으로 교체.

**옵션 A — 사내 CA 발급 인증서:**

```bash
# 1) dev 모드 symlink 제거 (있으면)
[[ -L nginx/certs/server.crt ]] && rm nginx/certs/server.crt
[[ -L nginx/certs/server.key ]] && rm nginx/certs/server.key

# 2) 사내 CA가 발급한 인증서를 일반 파일로 배치
cp /path/to/사내CA발급/server.crt nginx/certs/server.crt
cp /path/to/사내CA발급/server.key nginx/certs/server.key
chmod 644 nginx/certs/server.crt
chmod 600 nginx/certs/server.key

# 3) (선택) 로컬 dev 산출물 정리 — 안 지워도 nginx가 참조하지 않음
# rm -rf nginx/certs/dev/

# 4) Nginx 재시작
docker compose restart nginx
```

이후 `./start.sh` 를 재실행해도 `is_production_cert` 가 issuer 를 보고 자동 보존(덮어쓰지 않음). 자세한 절차는 [`docs/guides/internal-ca-certificate-guide.md`](../guides/internal-ca-certificate-guide.md).

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

`config/users.conf`의 `USERS` 배열이 PoC 샘플 인원(alice@local 등)을 등록한다. 사내 실 인원으로 교체:

```bash
# config/users.conf 편집 — 4-field 포맷 (SLOT|EMAIL|NAME[|ALLOWED_IPS])
ADMIN_EMAIL="admin@사내도메인.com"
USERS=(
  "user01|honggildong@사내도메인.com|홍길동"
  "user02|kimchulsoo@사내도메인.com|김철수|10.0.1.0/24"   # IP 바인딩 옵션
  # ... 10명까지
)
```

수정 후 `./start.sh` 재실행. 멱등이라 안전 (이미 등록된 사용자는 건너뛰고, 새 사용자만 추가). OpenAI Key는 §4.1로 OpenBao에 별도 적재.

> ALLOWED_IPS는 LiteLLM `/key/generate`의 `allowed_ips` 파라미터로 전달되어 Virtual Key가 그 IP에서만 유효해진다. 환경에 따라 LiteLLM이 source IP 인식 — uvicorn `proxy_headers` 설정 또는 nginx 직접 통신 — 이 필요할 수 있다. `tests/07-test-ip-binding.sh`는 발급/조회 라운드트립을 검증한다.

### 4.5 인증 모델 — Virtual Key API 중심 (UI 로그인 X)

> ⚠️ **중요 — LiteLLM OSS 제약**: Internal User의 UI password 로그인은 LiteLLM 내부에서 `TypeError: 'str' and 'NoneType'` 500 에러가 발생하는 알려진 버그가 있어 **사용하지 않는다**. 따라서 본 시스템은 **사용자가 UI에 로그인하지 않고 Virtual Key를 API/CLI로 사용**하는 모델로 운영한다.

| 역할 | 인증 방법 | UI 접근 | API 접근 |
|------|---------|--------|---------|
| 관리자 | UI: `admin` + `LITELLM_MASTER_KEY` | ✓ Logs, Users, Models, Usage 모니터링 | ✓ Master Key로 모든 엔드포인트 |
| 일반 사용자 | Virtual Key (24h TTL) | ✗ 불가 (PoC) | ✓ `/v1/chat/completions`, `/key/info` |

**사용자 onboarding 흐름:**

1. 관리자가 `./start.sh` 실행 → `scripts/sample-keys.txt`에 발급된 Virtual Key 10줄 생성
2. 관리자가 각 사용자에게 다음을 안전한 채널(사내 메신저 다이렉트, 이메일)로 전달:
   - 게이트웨이 URL (예: `https://192.168.1.50`)
   - 본인 Virtual Key (예: `sk-vk-abc...`)
   - 본인 슬롯 (예: `user01-gpt-4o`, `user01-o3-mini`)
   - `client-tools/check-info.sh` 스크립트
3. 사용자는 다음을 본인 PC에서 설정:
   ```bash
   export GATEWAY_URL="https://192.168.1.50"
   export OPENAI_API_KEY="sk-vk-abc..."

   # Codex CLI
   mkdir -p ~/.codex
   cat > ~/.codex/config.toml << 'TOML'
   openai_base_url = "https://192.168.1.50/v1"
   model = "user01-gpt-4o"
   approval_mode = "suggest"
   TOML

   # 본인 사용량 확인
   ./check-info.sh
   ```
4. 24h 후 Key 만료 → 관리자가 `./start.sh` 재실행하여 새 Key 발급, 사용자에게 재배포

**일별 Key 회전 자동화 (관리자):**

```bash
# 매일 자정에 ./start.sh 재실행하여 새 24h Key 발급
crontab -e
# 추가:
0 0 * * * cd /home/sung/Workspace/llm-access-gateway && ./start.sh >> /var/log/llm-gateway-rotate.log 2>&1
```

cron 실행 후 `scripts/sample-keys.txt`를 사용자별로 분리하여 자동 발송하는 스크립트는 향후 추가 가능 (사내 메신저 API 연동).

**기존 PoC 샘플 사용자 제거** (실 인원으로 전환 시):

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

[2] 사용자 메타데이터 설정
    □ ./start.sh 1회 실행 (config/users.conf 자동 생성됨)
    □ config/users.conf 편집 — ADMIN_EMAIL, USERS 배열(SLOT|EMAIL|NAME)을 사내 실값으로
       (OpenAI Key는 여기 적지 않음 — [5] 단계에서 OpenBao에 직접 적재)

[3] 부트스트랩 (전체 자동 적용)
    □ ./start.sh 재실행
    □ Phase 7 검증 테스트 6개 모두 통과 확인 (placeholder Key 상태에서도 5/6 통과)
    □ scripts/sample-keys.txt 생성 확인

[4] OpenBao Unseal 키 백업 (보안 필수)
    □ openbao/init-keys.json 을 안전한 오프라인 매체에 복사
    □ Unseal 키 5개를 5명의 다른 책임자에게 분산 보관
    □ 서버의 init-keys.json 권한 점검 (600)

[5] 실 OpenAI API Key 적재 (§4.1) — OpenBao에 직접
    □ OpenAI 콘솔에서 사용자별 Key 발급 (IP 화이트리스트 / 한도 / 알림 설정)
    □ ./scripts/set-openai-key.sh userNN sk-proj-...   (10슬롯 모두 또는 사용 슬롯만)
    □ ./start.sh 재실행 → .env로 미러링 + LiteLLM 재기동
    □ 사용자 1명으로 실 API 호출 → OpenAI 정상 응답 확인

[6] TLS 운영 인증서 교체 (§4.3)
    □ 사내 CA 또는 Let's Encrypt 인증서로 교체
    □ .env 의 PROXY_BASE_URL 을 실 도메인으로 변경
    □ docker compose restart nginx

[7] SSO 활성화 (선택, 운영 시 권장, §4.2)
    □ IdP에 OIDC 클라이언트 등록 + 그룹 생성
    □ .env 의 GENERIC_* 항목 채움
    □ ALLOWED_USER_EMAIL_DOMAINS 사내 도메인으로 설정
    □ docker compose up -d --force-recreate litellm  (.env 변경 반영)
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
| `openbao/init-keys.json` | 1회 (변경 없음) | 오프라인 매체 — 분실 시 복구 불가 |
| `openbao/data/` | 매일 | `tar czf` (모든 시크릿이 여기에) |
| `openbao/logs/audit.log` | 매일 또는 회전 | 외부 SIEM / `tar czf` |
| PostgreSQL DB | 매일 | `pg_dump` (사용자/Virtual Key/Spend) |
| `config/users.conf` | 변경 시 | 안전한 비밀 관리 도구 (메타데이터 SSOT) |
| `.env` | 변경 시 | 안전한 비밀 관리 도구 (Master Key 포함) |
| `nginx/certs/` | 인증서 갱신 시 | 안전한 매체 |
| `secrets/openbao-approle.env` | (재발급 가능) | 백업 불필요 — `start.sh`가 멱등 재발급 |
| `secrets/litellm-secrets.env` | (재발급 가능) | 백업 불필요 — `02-load-secrets.sh`가 OpenBao에서 재렌더 |

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
#    Phase 4가 OpenBao → .env 동기화를 수행하므로
#    .env의 USERnn_OPENAI_KEY 값은 백업본이 아닌 OpenBao의 현재 값으로 갱신됨
./start.sh

# 6. PostgreSQL 복원 (필요 시)
docker exec -i litellm-db psql -U litellm litellm < /backup/litellm-db.sql
docker compose up -d --force-recreate litellm
```

---

## 7. 비밀 노출 시 즉시 대응

### 7.1 `init-keys.json` 또는 OpenBao Root Token 노출

```bash
# 1. 현재 root token으로 새 root 발급
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('openbao/init-keys.json'))['root_token'])")
NEW_TOKEN=$(docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao token create -policy=root -format=json \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")

# 2. 기존 Root Token revoke
docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao bao token revoke -self

# 3. init-keys.json의 root_token 필드 갱신 (오프라인 백업도 동시 갱신)
python3 -c "
import json, os
p = 'openbao/init-keys.json'
d = json.load(open(p))
d['root_token'] = os.environ['NEW_TOKEN']
open(p,'w').write(json.dumps(d, indent=2))
" NEW_TOKEN="$NEW_TOKEN"

# 4. AppRole secret-id도 회전 (read-only지만 보수적으로)
rm -f secrets/openbao-approle.env
./start.sh   # AppRole 재발급 + 모든 단계 재확인

# 5. 모든 사용자 OpenAI Key를 OpenAI Console에서 회전 (§4.1로 새 키 적재)
```

> **참고**: `.env`에는 더 이상 `OPENBAO_ROOT_TOKEN`이 저장되지 않는다. root token은 `openbao/init-keys.json`에서만 직접 읽으므로 .env 갱신은 불필요.

### 7.2 `.env`의 `LITELLM_MASTER_KEY` 노출

```bash
# 새 Master Key 발급
NEW_MK="sk-master-$(openssl rand -hex 24)"
sed -i "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=${NEW_MK}|" .env
docker compose up -d --force-recreate litellm  # .env 변경 반영

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

1. OpenAI Console에서 해당 키를 즉시 revoke
2. 새 Key 발급 (콘솔에서 IP 화이트리스트 / 한도 동일하게)
3. `./scripts/set-openai-key.sh userNN sk-proj-NEW...`
4. `./start.sh` (또는 `bash scripts/02-load-secrets.sh && docker compose up -d --force-recreate litellm`)
5. 해당 사용자의 직전 Virtual Key도 폐기 권장 — Master Key로 `/key/delete` 호출 후 재발급 (`./start.sh`)

---

## 8. 자주 묻는 질문

**Q. `start.sh`를 두 번 실행하면 비밀 파일이 덮어써지는가?**

아니다. 모든 자동 생성 단계는 멱등(idempotent)으로 작성되었다. 이미 존재하는 `.env`, `init-keys.json`, TLS 인증서는 재사용된다. 기존 OpenBao 시크릿도 보존된다.

**Q. `.env`만 삭제하고 `./start.sh` 다시 돌렸더니 LiteLLM이 PostgreSQL 인증 실패(P1000)로 안 뜬다.**

`./start.sh`가 새 `.env`를 만들 때 새 랜덤 `POSTGRES_PASSWORD`를 생성하지만, 기존 `postgres-data` 볼륨에는 옛 비밀번호가 저장되어 있어 mismatch가 발생한다.

**해결**: 본 시스템은 postgres를 docker 내부 네트워크 전용으로 두고 컨테이너 간 TCP를 **trust 인증**으로 처리한다 (postgres 포트가 호스트에 노출되지 않으므로 안전한 절충). `./start.sh`의 Phase 4b가 매번 `pg_hba.conf`를 확인하여 trust 라인이 없으면 자동 패치 후 reload하므로 — 그냥 `./start.sh`를 다시 돌리면 자동 복구된다.

trust 인증 적용으로 `POSTGRES_PASSWORD`는 사실상 vestigial이 되며 LiteLLM의 `DATABASE_URL`에 어떤 값이 있어도 연결 성공한다. 이는 trade-off: 같은 docker 네트워크의 다른 컨테이너에서 postgres에 무인증 접근 가능하므로, **포트 노출이나 외부 네트워크 공유는 절대 허용하지 말 것**.

수동 복구가 필요하면 (start.sh가 어떤 이유로 패치하지 못한 경우):

```bash
# pg_hba.conf 직접 패치
docker compose up -d postgres
docker exec litellm-db sh -c '
  HBA=/var/lib/postgresql/data/pg_hba.conf
  sed -i -E "/^host[ \t]+all[ \t]+all[ \t]+all[ \t]+/d" "$HBA"
  echo "host all all all trust" >> "$HBA"
'
docker exec -u postgres litellm-db pg_ctl reload -D /var/lib/postgresql/data
docker compose up -d --force-recreate litellm

# 또는 전체 초기화 (DB 데이터 손실)
./reset.sh
./start.sh
```

**Q. `PROXY_BASE_URL`은 어떻게 결정되는가? IP가 바뀌면?**

`./start.sh`가 .env를 처음 만들 때 호스트의 outbound IP를 `ip route get 1.1.1.1`로 감지하여 `https://<IP>` 형식으로 설정한다. 호스트 IP가 바뀌거나 도메인을 쓰려면 `.env`의 `PROXY_BASE_URL` 값을 직접 편집한 뒤:

```bash
docker compose up -d --force-recreate litellm
```

**Q. `reset.sh`는 무엇을 삭제하는가?**

`reset.sh`는 `.env`, `init-keys.json`, OpenBao 데이터, PostgreSQL 볼륨, TLS 인증서, `sample-keys.txt`를 모두 삭제하고 컨테이너를 내린다. **백업 없이 실행하면 모든 데이터를 잃는다.** 사용자 확인을 받은 뒤에만 동작.

**Q. SSO 없이 사용자가 본인의 Virtual Key를 어떻게 받는가?**

PoC에서는 관리자가 `scripts/sample-keys.txt`에서 해당 사용자의 Key를 안전한 채널(이메일/사내 메신저)로 전달. SSO 활성화 후에는 사용자가 직접 UI 로그인하여 발급/조회.

**Q. 사용자가 11명 이상 필요하면?**

D2 §19.1 "신규 사용자 추가" 절차를 본 아키텍처에 맞게 적용:
1. **OpenBao에 새 OpenAI Key 추가**: `bao kv put secret/litellm/USER11_OPENAI_KEY key="sk-proj-..."`
2. **`litellm/config.yaml`에 모델 항목 2개 추가**: `user11-gpt-4o`, `user11-o3-mini`
3. **`docker-compose.yml`의 LiteLLM `environment:` 섹션에 한 줄 추가**: `USER11_OPENAI_KEY: "${USER11_OPENAI_KEY:-}"`
4. **`scripts/02-load-secrets.sh`의 for 루프 범위 확장** (`01..10` → `01..11`)
5. **sync + 재생성**: `bash scripts/02-load-secrets.sh && docker compose up -d --force-recreate litellm`
6. **사용자 등록**: `/user/new` API 또는 `scripts/03-register-users.sh`의 USERS 배열에 추가 후 재실행

**Q. 왜 OpenBao를 거치고 또 `.env`로 동기화하는가? 그냥 `.env`만 쓰면 되지 않나?**

OpenBao를 시크릿의 master로 두는 이유:
- **감사 로그**: 누가 언제 어떤 시크릿에 접근했는지 OpenBao 감사 로그로 추적 가능
- **접근 제어**: 시크릿별 정책 분리 가능 (사용자별 토큰 발급 등)
- **버전 관리**: KV v2는 시크릿의 이전 버전을 보존하므로 잘못된 갱신 시 롤백 가능
- **회전 워크플로우**: 자동/주기적 회전 정책 적용 가능
- **Enterprise 전환 시 무손실**: LiteLLM Enterprise를 도입하면 `key_management_system: "hashicorp_vault"`만 추가하면 되고, 기존 OpenBao 데이터/구조는 그대로 사용됨

`.env`는 LiteLLM OSS가 vault 직접 연동을 지원하지 않기 때문에 두는 임시 캐시 — Enterprise 라이선스 도입 시 제거 가능한 계층이다.

**Q. `.gitignore`에 추가해야 할 파일이 더 있는가?**

다음을 만들면 추가:
- `scripts/load-real-keys.sh` (실 OpenAI Key 적재 스크립트)
- `backup/` (로컬 백업 디렉토리)
- `*.sql` (DB 덤프)
- `*.tar.gz` (백업 압축 파일)
