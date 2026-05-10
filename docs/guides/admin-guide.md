# 관리자 가이드

게이트웨이를 호스팅하는 **관리자** 대상 운영 안내서.
일반 사용자용 안내는 [user-guide.md](user-guide.md)에 있다.

---

## 1. 무엇을 어디에 작성하고 무엇을 실행하는가 (한눈에)

| 단계 | 편집할 곳 | 실행할 명령 | 결과 |
|------|----------|-------------|------|
| **최초 설치** | (없음 — 자동) | `./start.sh` | `.env`, TLS 인증서, OpenBao, DB, 사용자 등록, Virtual Key 발급, 통합테스트까지 |
| **OpenAI Key 적재 / 회전** | **OpenBao (직접)** | `./scripts/set-openai-key.sh user01 sk-proj-...` | OpenBao에 기록. `./start.sh` 재실행 시 `.env`로 자동 미러링 |
| **사용자 메타데이터 편집** | `config/users.conf` (slot/email/name만) | `./start.sh` | LiteLLM 사용자 갱신 + 새 Virtual Key 재발급 |
| **환경변수 미세조정** | `.env` (PROXY_BASE_URL 등) | `docker compose restart litellm` | (`USERnn_OPENAI_KEY` 줄은 직접 편집 금지 — OpenBao에서 갱신) |
| **SSO 활성화** | `.env` (`GENERIC_*`) | `./start.sh` | `docker-compose.sso.yml` 자동 머지 |
| **사용자에게 Virtual Key 배포** | (없음) | `cat scripts/sample-keys.txt` | 줄 단위로 안전 채널 전달 |
| **본인정보 조회 도구 배포** | (없음) | `client-tools/` 디렉토리 전달 | `check-info.sh` + README |
| **일시 정지 (데이터 보존)** | (없음) | `./stop.sh` | 컨테이너 down. 다음 `./start.sh`로 복귀 |
| **완전 초기화 (데이터 삭제)** | (없음) | `./reset.sh` | 모든 시크릿/DB/Key 삭제 — `yes` 확인 |
| **로그/요청기록 열람** | (없음) | `https://<host>/ui` Master Key 로그인 | UI Logs 탭 |

> **핵심 원칙**:
> - **OpenAI Key의 source of truth = OpenBao**. 평문 파일에 두지 않는다 (관리자가 OpenAI 콘솔에서 발급 직후 `set-openai-key.sh`로 OpenBao에 직접 적재).
> - **사용자 메타데이터의 source of truth = `config/users.conf`** (slot/email/name만, OpenAI Key 없음).
> - 그 외는 `start.sh`가 멱등으로 처리.

---

## 2. 사전 요구사항

| 항목 | 확인 명령 |
|------|----------|
| Docker 데몬 실행 | `docker info` |
| Docker Compose v2 | `docker compose version` |
| `curl`, `openssl`, `python3` | (기본 설치) |
| 호스트 포트 80/443 사용 가능 | `ss -ltnp \| grep -E ':(80\|443)\b'` |

WSL2에서 Docker Desktop을 쓰려면 Docker Desktop → Settings → Resources → WSL Integration에서 해당 배포판을 켜야 한다.

---

## 3. 최초 설치

```bash
git clone <저장소> llm-access-gateway
cd llm-access-gateway
./start.sh
```

`start.sh`가 멱등으로 다음 8단계를 수행한다.

| Phase | 내용 |
|-------|------|
| 0 | docker / curl / openssl / python3 / Docker daemon 점검 |
| 1 | `.env`, TLS 자체서명 인증서, `config/users.conf` 자동 생성 (없을 때만) |
| 2 | OpenBao 컨테이너 기동 |
| 3 | OpenBao 초기화·Unseal·KV 마운트 (`openbao/init-keys.json` 생성) |
| 4 | OpenBao→`.env` 미러링 (실 Key가 적재되어 있으면 그 값, 아니면 placeholder) |
| 4b | PostgreSQL `pg_hba.conf` 정합성 보정 (멱등) |
| 5 | PostgreSQL + LiteLLM + Nginx 기동 + readiness 대기 |
| 6 | LiteLLM에 사용자 10명 + 관리자 등록, 24h Virtual Key 발급 → `scripts/sample-keys.txt` |
| 7 | 6개 통합 검증 테스트 (health / models / key / isolation / vault / RBAC) |
| 8 | 요약 출력 — UI URL, Master Key, sample-keys.txt 위치 |

완료 시점에 화면에 다음이 표시된다.

```
  Admin UI:    https://<host>/ui   (use Master Key to log in)
  API base:    https://<host>/v1
  Master Key:  sk-master-........
  10 sample Virtual Keys saved to: .../scripts/sample-keys.txt
```

---

## 4. OpenAI Key 관리 (OpenBao 직접)

OpenAI Key는 평문 파일에 두지 않는다. 관리자가 OpenAI 콘솔에서 Key를 발급한 직후 OpenBao에 직접 적재한다.

### 4.1 데이터 흐름

```
[OpenAI 콘솔 — IP/조직 정책 설정 후 Key 발급]
              │
              ▼   set-openai-key.sh (또는 bao kv put)
[OpenBao   secret/litellm/USERnn_OPENAI_KEY]   ← single source of truth (저장 시 암호화)
              │
              ▼   start.sh / 02-load-secrets.sh
[.env       USERnn_OPENAI_KEY=...]             ← 캐시 (chmod 600, 직접 편집 금지)
              │
              ▼   docker-compose env_file
[LiteLLM 컨테이너 OS env]                       ← os.environ/USERnn_OPENAI_KEY 표기로 참조
```

> `.env` 단계가 남아있는 이유는 LiteLLM OSS가 Vault 직접 연동을 지원하지 않기 때문(Enterprise 전용). OpenBao를 거쳐 OS env로 우회 주입하는 우회 구조다. 관리자/사용자가 손으로 만지는 source는 **OpenBao 한 곳**으로 정리되어 있다.

### 4.2 OpenAI 콘솔에서 해야 할 것 (권장)

1. **사용자별로 별도의 API Key 발급** (slot 1:1, 사용자 단위 사용량 분리 가능)
2. **IP 화이트리스트** — 게이트웨이(LiteLLM) 호스트의 outbound IP를 등록
3. **사용량 한도 / 알림** — 사용자별 / 조직 차원
4. Key 문자열은 콘솔 표시 직후가 마지막 노출 기회 — 즉시 OpenBao에 적재(아래 §4.3) 후 콘솔 창을 닫는다.

### 4.3 OpenBao에 적재

**(권장) 헬퍼 스크립트** — 인자로 직접:

```bash
./scripts/set-openai-key.sh user01 sk-proj-AAAA...
```

**(권장) 헬퍼 스크립트 — 셸 히스토리에 키를 남기지 않으려면 stdin**:

```bash
./scripts/set-openai-key.sh user01 -
# 키 붙여넣기 후 Ctrl-D
```

**(직접) `bao` CLI**:

```bash
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('openbao/init-keys.json'))['root_token'])")
docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER01_OPENAI_KEY key="sk-proj-..."
```

**(GUI) OpenBao Web UI**:
`http://<host>:8200` (PoC 기본 비공개) — Login: Token = `init-keys.json`의 `root_token` → KV `secret/litellm/USERnn_OPENAI_KEY`.

### 4.4 적재 후 반영

```bash
./start.sh        # 멱등: OpenBao→.env 동기화 + LiteLLM 재기동 + Virtual Key 재발급
```

부분 갱신만 원하면:

```bash
./scripts/02-load-secrets.sh && docker compose restart litellm
```

### 4.5 Key 회전

OpenAI 콘솔에서 새 Key 발급 → `set-openai-key.sh user01 sk-proj-NEW...` → `./start.sh`. 구 키는 OpenAI 콘솔에서 즉시 revoke한다.

---

## 5. 사용자 메타데이터 편집 (`config/users.conf`)

**single source of truth = `config/users.conf`** (메타데이터만, OpenAI Key 없음).

### 5.1 파일 형식

```bash
# config/users.conf
ADMIN_EMAIL="admin@company.com"

USERS=(
  "user01|alice@company.com|홍길동"
  "user02|bob@company.com|김철수"
  # ...
)
```

각 항목 형식: `SLOT|EMAIL|NAME`

- `SLOT` — `user01` ~ `user10`. `litellm/config.yaml`의 `userNN-gpt-4o` / `userNN-o3-mini`와 1:1 매핑.
- `EMAIL` — 사용자 식별자 메타데이터.
- `NAME` — 표시 이름 (관리자 UI Logs 탭).

> 구 4-field 형식(`SLOT|EMAIL|NAME|KEY`)도 호환되지만 4번째 필드는 무시되고 경고가 출력된다. 마이그레이션 시 OpenBao로 옮기고 4번째 필드는 삭제할 것.

### 5.2 편집 후 실행

```bash
vi config/users.conf
./start.sh
```

`./start.sh`가 자동 처리:

1. OpenBao→`.env` 미러링 (USER01..10_OPENAI_KEY)
2. LiteLLM 컨테이너 재기동
3. 사용자 신규/갱신 (`/user/new` 또는 `/user/update`)
4. 새 24h Virtual Key 발급 → `scripts/sample-keys.txt`

### 5.3 사용자 추가 / 제거

- 추가: `USERS=(...)`에 새 줄 추가 → `./scripts/set-openai-key.sh userNN sk-proj-...` → `./start.sh`
- 제거: 해당 줄 삭제 → `./start.sh`. LiteLLM 사용자 레코드는 즉시 정리하려면 UI Internal Users 탭에서 비활성화/삭제.

> 슬롯 한도(기본 10)는 `litellm/config.yaml`이 user01~user10 모델 20개를 사전 선언해 둔 것에 의해 결정. 더 필요하면 `litellm/config.yaml`에 모델 매핑을 추가한 후 슬롯 번호를 늘린다.

---

## 6. Virtual Key 배포

`./start.sh` 실행 직후 `scripts/sample-keys.txt`가 다시 쓰여진다.

```bash
cat scripts/sample-keys.txt
```

```
# Generated 2026-05-10T14:50:03+00:00 — DO NOT COMMIT
# Format: <email> <slot> <name> <virtual_key>

alice@company.com user01 홍길동 sk-vk-abcd...
bob@company.com   user02 김철수 sk-vk-efgh...
...
```

각 줄을 해당 사용자에게 **안전한 채널**(사내 메신저 다이렉트, 회사 메일)로 전달.
사용자 측 사용법은 [user-guide.md](user-guide.md) 참조.

> Virtual Key는 24h 후 자동 만료된다. 매일 또는 사용자 요청 시 `./start.sh` 재실행 → 새 키 배포가 운영 사이클이다.

---

## 7. 사용자에게 함께 전달할 도구

`client-tools/` 디렉토리(2개 파일):

```
client-tools/
├── README.md         # 사용자가 본인 PC에서 보는 짧은 안내
└── check-info.sh     # 본인 사용량 / 잔여 예산 / 만료 시각 조회
```

가장 단순한 배포: `client-tools/`를 zip/scp로 전달하면서 본인의 Virtual Key 한 줄을 같이 알려준다.

---

## 8. 관리자 UI 사용 (모니터링)

`https://<host>/ui` 접속 → **Master Key**로 로그인.
(Master Key는 `.env`의 `LITELLM_MASTER_KEY` 값. `./start.sh` 종료 시 화면에도 출력)

| 탭 | 용도 |
|----|-----|
| **Logs** | 전체 사용자의 prompt/response/spend 시계열 (90d 보존) |
| **Internal Users** | 사용자 목록, 모델 매핑, 한도 |
| **Virtual Keys** | 발급된 Key 목록, 만료 시각, alias |
| **Models** | 매핑된 20개 (10 사용자 × 2 모델) |
| **Settings** | budget / TTL / SSO 등 |

> Internal User의 **password 로그인**은 LiteLLM OSS의 알려진 버그(500)로 사용하지 않는다. 사용자는 UI 로그인 없이 Virtual Key API/CLI로만 사용한다.

---

## 9. SSO 활성화 (선택)

사내 OIDC IdP를 연동하면 사용자도 UI 셀프서비스가 열린다.

`.env` 편집:

```bash
GENERIC_CLIENT_ID=<IdP에서 발급받은 client id>
GENERIC_CLIENT_SECRET=<client secret>
GENERIC_AUTHORIZATION_ENDPOINT=https://idp.사내/oauth2/authorize
GENERIC_TOKEN_ENDPOINT=https://idp.사내/oauth2/token
GENERIC_USERINFO_ENDPOINT=https://idp.사내/oauth2/userinfo
ALLOWED_USER_EMAIL_DOMAINS=company.com
```

후 `./start.sh`. `GENERIC_CLIENT_ID`가 채워져 있으면 `start.sh`가 자동으로 `docker-compose.sso.yml`을 머지한다.

자세한 IdP 설정 표는 [D2-system-requirements.md §9](../design/D2-system-requirements.md) 참조.

---

## 10. 일상 운영 명령

| 작업 | 명령 |
|------|------|
| 전체 상태 | `docker compose ps` |
| LiteLLM 로그 (실시간) | `docker compose logs -f litellm` |
| OpenBao 상태 | `docker exec openbao bao status` |
| OpenBao Unseal (재기동 후) | `./openbao/unseal.sh` |
| 정지 (데이터 보존) | `./stop.sh` |
| 완전 초기화 | `./reset.sh` |
| 통합 테스트만 재실행 | `./tests/test-all.sh` |
| OpenAI Key 직접 갱신 (vault) | `docker exec -e BAO_TOKEN=$ROOT_TOKEN openbao bao kv put secret/litellm/USER01_OPENAI_KEY key="sk-proj-..."` 후 `./start.sh` |

---

## 11. 백업 / 복구 핵심

| 자산 | 위치 | 분실 시 |
|------|------|---------|
| **OpenBao Unseal Keys + Root Token** | `openbao/init-keys.json` | **복구 불가** — 오프라인 백업 필수 |
| 시크릿 데이터 | Docker volume `openbao-data` | 위 키가 있어야 복원 가능 |
| 사용자/Key/Spend 로그 | Docker volume `postgres-data` | 사용자 다시 등록 필요 |
| TLS 인증서 | `nginx/certs/server.{crt,key}` | 재발급 가능 |
| 사용자 매핑 | `config/users.conf` | git에 없음 — 별도 백업 |

상세 절차: [docs/operations/secrets-and-config.md](../operations/secrets-and-config.md).

---

## 12. 실 운영 전 체크리스트

1. OpenAI 콘솔에서 사용자별 Key 발급(IP 화이트리스트 / 한도 설정) 후 `./scripts/set-openai-key.sh userNN sk-proj-...`로 OpenBao에 적재 (placeholder가 남지 않도록 10슬롯 모두)
2. `openbao/init-keys.json`을 오프라인 백업 후 서버에서 삭제(또는 권한 강화)
3. 자체서명 TLS → 사내 CA 또는 Let's Encrypt 교체
4. 방화벽: 80, 443 외 차단 (4000 / 5432 / 8200은 호스트에 노출 안 됨)
5. `LITELLM_MASTER_KEY`를 사내 비밀 관리 도구로 이관, 정기 로테이션
6. PostgreSQL volume 정기 백업 정책 수립
7. (선택) SSO 활성화 후 사용자 자율 가입/로그인 흐름 검증

자세한 표: [D2-system-requirements.md §20](../design/D2-system-requirements.md).

---

## 13. 트러블슈팅

| 증상 | 원인 / 해결 |
|------|------------|
| `Docker daemon is not running` | `sudo service docker start` 또는 Docker Desktop 시작 |
| Phase 5b LiteLLM ready 시간 초과 | `docker compose logs litellm`. 첫 실행은 PG 마이그레이션으로 30~60초 소요 |
| 테스트 04 (isolation) 실패 | `scripts/sample-keys.txt`가 비었는지 확인 — `register-users.sh` 재실행 |
| 테스트 05 (vault) 실패 | OpenBao Sealed → `./openbao/unseal.sh` |
| 사용자 401 (Codex) | Virtual Key 24h 만료. `./start.sh` 재실행 후 새 키 배포 |
| OpenAI 401 | OpenBao의 USERnn 슬롯이 placeholder 상태. `./scripts/set-openai-key.sh userNN sk-proj-...` 후 `./start.sh` |
| `pg_hba.conf` 인증 오류 | `start.sh` Phase 4b가 자동 보정. 그래도 실패하면 `./reset.sh` 후 재설치 |
| UI 로그인 후 즉시 500 | Internal User password 로그인 시도 — Master Key로만 로그인 |
| 호스트 IP 변경 후 redirect 깨짐 | `.env`의 `PROXY_BASE_URL`을 새 IP로 수정 후 `docker compose restart litellm` |

---

## 14. 관련 문서

- [user-guide.md](user-guide.md) — 사용자 배포용 안내
- [docs/operations/secrets-and-config.md](../operations/secrets-and-config.md) — 비밀 파일 상세
- [docs/design/D1-system-requirements.md](../design/D1-system-requirements.md) — v1 설계 (Virtual Key 단독)
- [docs/design/D2-system-requirements.md](../design/D2-system-requirements.md) — v2 설계 (SSO 통합)
- [docs/design/D3-implementation-plan.md](../design/D3-implementation-plan.md) — 본 PoC 구현 플랜
