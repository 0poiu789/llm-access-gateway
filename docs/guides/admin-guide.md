# 관리자 가이드

게이트웨이를 호스팅하는 **관리자** 대상 운영 안내서.
일반 사용자용 안내는 [user-guide.md](user-guide.md)에 있다.

---

## 1. 무엇을 어디에 작성하고 무엇을 실행하는가 (한눈에)

| 단계 | 편집할 곳 | 실행할 명령 | 결과 |
|------|----------|-------------|------|
| **최초 설치** | (없음 — 자동) | `./start.sh` | `.env`, TLS, OpenBao(+AppRole+Audit), DB, 사용자 등록, Virtual Key 발급, 통합테스트까지 |
| **OpenAI Key 적재 / 회전** | **OpenBao (직접)** | `./scripts/set-openai-key.sh user01 sk-proj-...` | OpenBao 기록 → `secrets/litellm-secrets.env` 자동 갱신 → LiteLLM 재기동 |
| **사용자 메타데이터 / IP 화이트리스트** | `config/users.conf` (slot/email/name[/allowed_ips]) | `./start.sh` | 사용자 갱신 + 새 24h Virtual Key 재발급 (allowed_ips 바인딩 포함) |
| **환경변수 미세조정** | `.env` (`PROXY_BASE_URL` 등) | `docker compose up -d --force-recreate litellm` | (`USERnn_OPENAI_KEY`는 `.env`에 더 이상 존재하지 않음) |
| **SSO 활성화** | `.env` (`GENERIC_*`) | `./start.sh` | `docker-compose.sso.yml` 자동 머지 |
| **Virtual Key 배포** | (없음) | `cat scripts/sample-keys.txt` | 줄 단위로 안전 채널 전달 |
| **본인정보 조회 도구 배포** | (없음) | `client-tools/` 디렉토리 전달 | `check-info.sh` + README |
| **OpenBao Web UI 접근(시크릿 직접 편집)** | (없음) | SSH 포트포워딩 (§10) | `http://localhost:8200/ui` |
| **일시 정지 (데이터 보존)** | (없음) | `./stop.sh` | 컨테이너 down |
| **완전 초기화 (데이터 삭제)** | (없음) | `./reset.sh` | 모든 시크릿/DB/Key 삭제 — `yes` 확인 |
| **로그/요청기록 열람** | (없음) | `https://<host>/ui` (Master Key) | UI Logs 탭 |

> **두 source of truth로 분리됨**:
> - **OpenAI Key의 SSOT = OpenBao** (`secret/litellm/USERnn_OPENAI_KEY`). 평문 파일에 두지 않음.
> - **사용자 메타데이터 SSOT = `config/users.conf`** (slot / email / name / 옵션 allowed_ips).
> - LiteLLM은 OpenBao에 **AppRole 토큰(read-only)**으로 접근. root token은 부트스트랩에만 사용.
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

`start.sh`가 멱등으로 다음 단계를 수행한다.

| Phase | 내용 |
|-------|------|
| 0 | docker / curl / openssl / python3 / Docker daemon 점검 |
| 1 | `.env`, TLS 자체서명 인증서, `config/users.conf`, `secrets/` 디렉토리 자동 생성 |
| 2 | OpenBao 컨테이너 기동 |
| 3 | OpenBao 초기화·Unseal·KV 마운트 + **AppRole(read-only 정책)** + **File audit device** (`openbao/logs/audit.log`) |
| 4 | OpenBao→`secrets/litellm-secrets.env` 미러링 (AppRole 토큰으로 read; 미적재 슬롯은 placeholder) |
| 4b | PostgreSQL `pg_hba.conf` 정합성 보정 (멱등) |
| 5 | PostgreSQL + LiteLLM + Nginx 기동 + readiness 대기 |
| 6 | LiteLLM에 사용자 등록(메타데이터+모델), 24h Virtual Key 일괄 발급 → `scripts/sample-keys.txt` |
| 7 | 통합 검증 테스트 (health / models / key / isolation / vault / RBAC / IP binding / AppRole+audit) |
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
[OpenAI 콘솔 — IP 화이트리스트/한도 설정 후 Key(C) 발급]
              │ 관리자 수작업
              ▼   ./scripts/set-openai-key.sh (root token, init-keys.json에서)
[OpenBao   secret/litellm/USERnn_OPENAI_KEY]   ← SSOT (저장 시 암호화) ─→ audit.log
              │  ↑
              │  └ AppRole "litellm" (read-only 정책)
              ▼     자동 인증 (secrets/openbao-approle.env에 role-id/secret-id)
              ▼   02-load-secrets.sh (AppRole 토큰)
[secrets/litellm-secrets.env (chmod 600)]      ← OS 캐시 (0700 디렉토리)
              │
              ▼   docker-compose env_file
[LiteLLM 컨테이너 OS env]                       ← os.environ/USERnn_OPENAI_KEY 표기로 참조
```

> 평문 캐시 단계가 남아 있는 이유: LiteLLM OSS는 OpenBao 직접 연동 미지원(Enterprise 전용). `secrets/litellm-secrets.env` 우회. 관리자/사용자가 손으로 만지는 source는 **OpenBao 한 곳**으로 정리.
>
> AppRole 토큰은 `secret/data/litellm/*` read만 가능. 쓰기는 root_token만 — 구조상 LiteLLM 컨테이너가 침해되어도 다른 시크릿을 노출시키거나 갱신할 수 없다.

### 4.2 OpenAI 콘솔에서 해야 할 것 (권장)

1. **사용자별로 별도의 API Key 발급** (slot 1:1, 사용자 단위 사용량 분리 가능)
2. **IP 화이트리스트** — 게이트웨이(LiteLLM) 호스트의 outbound IP를 등록
3. **사용량 한도 / 알림** — 사용자별 / 조직 차원
4. Key 문자열은 콘솔 표시 직후가 마지막 노출 기회 — 즉시 OpenBao에 적재(아래 §4.3) 후 콘솔 창을 닫는다.

### 4.3 OpenBao에 적재

**(권장) 헬퍼 스크립트** — 인자로 직접:

```bash
./scripts/set-openai-key.sh user01 sk-proj-AAAA...
# → OpenBao 기록 + secrets/litellm-secrets.env 갱신 + LiteLLM 재기동까지 자동
```

**(권장) 헬퍼 스크립트 — 셸 히스토리에 키를 남기지 않으려면 stdin**:

```bash
./scripts/set-openai-key.sh user01 -
# 키 붙여넣기 후 Ctrl-D
```

**일괄 적재 (--no-reload)**: 여러 슬롯을 차례대로 적재하고 한 번에 반영하고 싶으면 각 호출에 `--no-reload`를 붙이고 마지막에 `bash scripts/02-load-secrets.sh && docker compose up -d --force-recreate litellm`.

**(직접) `bao` CLI** — root token을 init-keys.json에서 읽어서:

```bash
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('openbao/init-keys.json'))['root_token'])")
docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER01_OPENAI_KEY key="sk-proj-..."
```

**(GUI) OpenBao Web UI** — §10의 SSH 포트포워딩으로 접속:
`http://localhost:8200/ui` → Login: Token = `init-keys.json`의 `root_token` → KV `secret/litellm/USERnn_OPENAI_KEY`.

### 4.4 적재 후 반영

`set-openai-key.sh`는 **자동으로 다음을 수행**한다:

1. OpenBao 기록 (root token)
2. `02-load-secrets.sh` 실행 — AppRole로 읽어 `secrets/litellm-secrets.env` 갱신
3. `docker compose up -d --force-recreate litellm` — 새 env 반영

별도로 `./start.sh`를 돌려도 결과는 동일(멱등).

### 4.5 Key 회전

```bash
# 1) OpenAI 콘솔에서 새 Key 발급
# 2) OpenBao 갱신
./scripts/set-openai-key.sh user01 sk-proj-NEW...
# 3) OpenAI 콘솔에서 구 Key revoke
```

---

## 5. 사용자 메타데이터 + IP 화이트리스트 (`config/users.conf`)

**SSOT = `config/users.conf`** (메타데이터만; OpenAI Key 없음).

### 5.1 파일 형식

```bash
# config/users.conf
ADMIN_EMAIL="admin@company.com"

USERS=(
  "user01|alice@company.com|홍길동"
  "user02|bob@company.com|김철수|10.0.1.0/24"          # IP 바인딩
  "user03|carol@company.com|이영희|10.0.2.5,10.0.2.6"   # 다중 IP
  # ...
)
```

각 항목 형식: `SLOT|EMAIL|NAME[|ALLOWED_IPS]`

| 필드 | 내용 |
|------|------|
| `SLOT` | `user01`~`user10`. `litellm/config.yaml`의 `userNN-gpt-4o`/`userNN-o3-mini`와 1:1 |
| `EMAIL` | 사용자 식별자 메타데이터 |
| `NAME` | 표시 이름 (관리자 UI Logs 탭) |
| `ALLOWED_IPS` (옵션) | 콤마 구분 IP/CIDR. Virtual Key가 이 IP에서만 유효. 비우거나 4번째 필드 자체를 생략하면 IP 제한 없음(기존 동작) |

> **현재 한계 (LiteLLM OSS 1.82.x)**: `/key/generate`는 `allowed_ips` 파라미터를 받지만, OSS 버전의 `LiteLLM_VerificationToken` 테이블에 해당 컬럼이 없어 **silent-drop**된다. 즉 ALLOWED_IPS는 클라이언트 측 wiring(`scripts/03-register-users.sh`)에서 정상 전송되지만 서버에서 영속화/시행되지 않는다. `tests/07-test-ip-binding.sh`도 이 사실을 informational로 표시한다.
>
> Enterprise 라이선스 또는 LiteLLM 업스트림 마이그레이션이 추가되는 즉시 현재 wiring이 자동으로 작동한다. 단기 운영에서 IP 제한이 필요하면 LiteLLM의 글로벌 `general_settings.allowed_ip_addresses`(게이트웨이 진입 IP 화이트리스트, 사용자별 아님)를 사용하거나 nginx 단에서 처리. 자세한 옵션은 [D4 §2.2 ⑤](../design/D4-reference-gap-analysis.md).

### 5.2 편집 후 실행

```bash
vi config/users.conf
./start.sh
```

`./start.sh`가 자동 처리:

1. AppRole로 OpenBao→`secrets/litellm-secrets.env` 미러링
2. LiteLLM 컨테이너 재기동
3. 사용자 신규/갱신 (`/user/new` 또는 `/user/update`)
4. 새 24h Virtual Key 발급 (allowed_ips 적용) → `scripts/sample-keys.txt`

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
# Format: <email> <slot> <name> <virtual_key>  [# allowed_ips=...]

alice@company.com user01 홍길동 sk-vk-abcd...
bob@company.com   user02 김철수 sk-vk-efgh...  # allowed_ips=10.0.1.0/24
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
└── check-info.sh     # 본인 사용량 / 잔여 예산 / 만료 시각 / allowed_ips 조회
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
| **Virtual Keys** | 발급된 Key 목록, 만료 시각, alias, allowed_ips |
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

자세한 IdP 설정 표는 [D2 §9](../design/D2-system-requirements.md), 갭 분석은 [D4 §3·§4.6](../design/D4-reference-gap-analysis.md) 참조.

---

## 10. OpenBao Web UI / CLI 직접 접근 (관리자)

OpenBao의 8200 포트는 보안상 호스트에 노출되지 않는다. 관리자가 시크릿/정책/Audit을 GUI로 직접 보거나 편집하려면 SSH 포트포워딩을 사용한다.

```bash
# 관리자 PC에서
ssh -L 8200:127.0.0.1:8200 user@gateway-host

# (게이트웨이 호스트에서 docker가 8200을 호스트 루프백에 노출하지 않으므로)
# → 게이트웨이 호스트로 들어간 다음, openbao 컨테이너로 한 번 더 forward:
ssh user@gateway-host -L 8200:127.0.0.1:8200 \
  -t 'docker run --rm -i --network llm-access-gateway_llm-net \
       alpine/socat tcp-listen:8200,fork,reuseaddr tcp-connect:openbao:8200'
# 또는 더 간단히: 호스트에서 docker-compose에 `ports: ["127.0.0.1:8200:8200"]` 한시적 추가 후 SSH -L
```

브라우저 → `http://localhost:8200/ui` → root token(=`init-keys.json`의 `root_token`) 입력 → KV/AppRole/Audit 모두 GUI로 가능.

CLI 사용은 호스트에서 바로:

```bash
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('openbao/init-keys.json'))['root_token'])")
docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao bao kv list secret/litellm/
docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao bao audit list
docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao bao policy read litellm-readonly
```

> 운영 환경에서는 nginx에 IP 제한된 `/openbao/` 경로를 추가하거나(D4 WI-5 옵션 A), VPN을 통한 8200 접근만 허용하는 것이 권장. PoC 기본은 SSH 포워딩만 노출.

---

## 11. 일상 운영 명령

| 작업 | 명령 |
|------|------|
| 전체 상태 | `docker compose ps` |
| LiteLLM 로그 (실시간) | `docker compose logs -f litellm` |
| OpenBao 상태 | `docker exec openbao bao status` |
| OpenBao Unseal (재기동 후) | `./openbao/unseal.sh` |
| OpenBao Audit 확인 | `tail -F openbao/logs/audit.log` |
| AppRole 자격 재발급 | `./reset.sh` 또는 `rm secrets/openbao-approle.env && ./start.sh` |
| 정지 (데이터 보존) | `./stop.sh` |
| 완전 초기화 | `./reset.sh` |
| 통합 테스트만 재실행 | `./tests/test-all.sh` |
| 매일 24h Virtual Key 일괄 재발급 | `./start.sh` (cron 등록 권장) |

---

## 12. 백업 / 복구 핵심

| 자산 | 위치 | 분실 시 |
|------|------|---------|
| **OpenBao Unseal Keys + Root Token** | `openbao/init-keys.json` | **복구 불가** — 오프라인 백업 필수 |
| 시크릿 데이터 | Docker volume / `openbao/data/` | 위 키가 있어야 복원 가능 |
| AppRole 자격증명 | `secrets/openbao-approle.env` | 재발급 가능 (`./start.sh` 멱등) |
| 사용자/Key/Spend 로그 | Docker volume `postgres-data` | 사용자 다시 등록 필요 |
| TLS 인증서 | `nginx/certs/server.{crt,key}` | 재발급 가능 |
| 사용자 매핑 | `config/users.conf` | git에 없음 — 별도 백업 |
| Audit log | `openbao/logs/audit.log` | 보존 정책 별도 수립 (회전, 외부 SIEM 연동 등) |

상세 절차: [docs/operations/secrets-and-config.md](../operations/secrets-and-config.md).

---

## 13. 실 운영 전 체크리스트

1. OpenAI 콘솔에서 사용자별 Key 발급(IP 화이트리스트 / 한도 설정) 후 `./scripts/set-openai-key.sh userNN sk-proj-...`로 OpenBao에 적재 (placeholder가 남지 않도록 사용 슬롯 모두)
2. `openbao/init-keys.json`을 오프라인 백업 후 서버에서 삭제(또는 권한 강화). root token은 응급 시에만 사용
3. 자체서명 TLS → 사내 CA 또는 Let's Encrypt 교체
4. 방화벽: 80, 443 외 차단 (4000 / 5432 / 8200은 호스트에 노출 안 됨)
5. `LITELLM_MASTER_KEY`를 사내 비밀 관리 도구로 이관, 정기 로테이션
6. PostgreSQL volume 정기 백업 정책 수립
7. Audit log 로테이션/보존 정책 수립 (PoC는 무한 누적)
8. (선택) 사용자별 ALLOWED_IPS 적용, uvicorn proxy_headers 신뢰 설정 검증
9. (선택) SSO 활성화 후 사용자 자율 가입/로그인 흐름 검증

자세한 표: [D2 §20](../design/D2-system-requirements.md), 개선 로드맵: [D4 §4·§5](../design/D4-reference-gap-analysis.md).

---

## 14. 트러블슈팅

| 증상 | 원인 / 해결 |
|------|------------|
| `Docker daemon is not running` | `sudo service docker start` 또는 Docker Desktop 시작 |
| Phase 5b LiteLLM ready 시간 초과 | `docker compose logs litellm`. 첫 실행은 PG 마이그레이션으로 30~60초 소요 |
| Phase 4 `AppRole login failed` | `secrets/openbao-approle.env`의 secret-id 무효화. `rm secrets/openbao-approle.env && ./start.sh` |
| 테스트 04 (isolation) 실패 | OpenAI 401(placeholder) — 본문 패턴으로 LiteLLM 401과 구분. 실제 키 적재 후 200 |
| 테스트 05 (OpenBao) 실패 | OpenBao Sealed → `./openbao/unseal.sh` |
| 테스트 08 (AppRole+audit) 실패 | `openbao/logs/audit.log`가 비어있음 → audit device 재활성: `docker exec -e BAO_TOKEN=$ROOT openbao bao audit enable -path=file file file_path=/openbao/logs/audit.log` |
| 사용자 401 (Codex) | Virtual Key 24h 만료 또는 allowed_ips 불일치. `./start.sh` 재실행 후 새 키 배포 |
| OpenAI 401 | OpenBao의 USERnn 슬롯이 placeholder 상태. `./scripts/set-openai-key.sh userNN sk-proj-...` |
| `pg_hba.conf` 인증 오류 | `start.sh` Phase 4b가 자동 보정. 그래도 실패하면 `./reset.sh` 후 재설치 |
| UI 로그인 후 즉시 500 | Internal User password 로그인 시도 — Master Key로만 로그인 |
| 호스트 IP 변경 후 redirect 깨짐 | `.env`의 `PROXY_BASE_URL`을 새 IP로 수정 후 `docker compose up -d --force-recreate litellm` |
| OpenBao init 시 `permission denied: /openbao/data/core` | 호스트 `openbao/data/`/`logs/` 디렉토리 소유자 mismatch. `start.sh` Phase 1이 `chmod 777`로 자동 보정. 보정 안 되면 `./reset.sh` |

---

## 15. 관련 문서

- [user-guide.md](user-guide.md) — 사용자 배포용 안내
- [docs/operations/secrets-and-config.md](../operations/secrets-and-config.md) — 비밀 파일 상세
- [docs/design/D1-system-requirements.md](../design/D1-system-requirements.md) — v1 설계 (Virtual Key 단독)
- [docs/design/D2-system-requirements.md](../design/D2-system-requirements.md) — v2 설계 (SSO 통합)
- [docs/design/D3-implementation-plan.md](../design/D3-implementation-plan.md) — 본 PoC 구현 플랜
- [docs/design/D4-reference-gap-analysis.md](../design/D4-reference-gap-analysis.md) — 참조 아키텍처 갭 분석 + 개선 설계 (WI-1~6)
