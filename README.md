# LLM Access Gateway

OpenBao + LiteLLM Proxy 기반 사용자별 OpenAI Key 격리 LLM 게이트웨이 (PoC).

> 역할별 상세 안내
> - 🛠 **관리자** — 설치 / Key 발급 / 모니터링: [docs/guides/admin-guide.md](docs/guides/admin-guide.md)
> - 👤 **일반 사용자** — Codex CLI / API 사용: [docs/guides/user-guide.md](docs/guides/user-guide.md)

---

## 빠른 시작 (관리자, 1줄)

```bash
./start.sh
```

이 한 줄로 자동 수행:
`.env`/TLS/OpenBao 초기화 → 서비스 4개(OpenBao·PG·LiteLLM·Nginx) 기동 → 사용자 10명 등록 → 24h Virtual Key 10개 발급 → 6개 통합 테스트 → 요약 출력.

완료 후 출력되는 것:
- **Admin UI**: `https://<host>/ui` (Master Key로 로그인)
- **API base**: `https://<host>/v1`
- **Master Key**: `.env`의 `LITELLM_MASTER_KEY`
- **Virtual Key 10개**: [scripts/sample-keys.txt](scripts/sample-keys.txt) — 각 줄을 해당 사용자에게 안전 채널로 전달

### 사전 요구사항

`docker info` 가 성공해야 한다. 그 외 `docker compose` v2, `curl`, `openssl`, `python3`. WSL2는 Docker Desktop의 WSL Integration 활성화 필요.

### OpenAI Key 적재 (관리자가 OpenBao에 직접)

평문 파일에 두지 않는다. OpenAI 콘솔에서 발급 직후:

```bash
./scripts/set-openai-key.sh user01 sk-proj-실제-키-...
./start.sh   # OpenBao → .env 미러링 + LiteLLM 재기동
```

상세 — IP 화이트리스트 / Key 회전 / `bao kv put` 직접 사용: [admin-guide.md §4](docs/guides/admin-guide.md).

### 사용자 메타데이터 편집

[config/users.conf](config/users.conf.example) — `SLOT|EMAIL|NAME` 3-field만:

```bash
USERS=(
  "user01|alice@company.com|홍길동"
  "user02|bob@company.com|김철수"
  ...
)
```

편집 후 `./start.sh` 재실행하면 LiteLLM 사용자 + Virtual Key가 갱신된다.

---

## 빠른 시작 (사용자, 3단계)

관리자에게 받은 것: **게이트웨이 주소**, **Virtual Key**(`sk-vk-...`), **본인 슬롯**(`userNN`).

```bash
# 1) 환경변수
export GATEWAY_URL="https://<관리자에게_받은_주소>"
export OPENAI_API_KEY="sk-vk-..."

# 2) 본인 정보 확인 (관리자가 함께 전달한 client-tools/)
./client-tools/check-info.sh

# 3) Codex CLI 설정
mkdir -p ~/.codex && cat > ~/.codex/config.toml <<TOML
openai_base_url = "${GATEWAY_URL}/v1"
model = "user01-gpt-4o"   # 본인 슬롯 번호로 교체
approval_mode = "suggest"
TOML

codex
```

24시간 후 Key가 만료되면 관리자에게 새 키를 요청한다.
자세한 설명·OpenAI SDK 예시·FAQ → [user-guide.md](docs/guides/user-guide.md).

---

## 디렉토리 구조

```
.
├── start.sh / stop.sh / reset.sh    # 단일 진입점 / 정지(보존) / 초기화(삭제)
├── docker-compose.yml               # OpenBao + PG + LiteLLM + Nginx
├── docker-compose.sso.yml           # SSO 활성화 시 자동 머지
├── .env / .env.example              # 자동 생성, chmod 600
├── config/users.conf                # 사용자 메타데이터 (slot/email/name) — OpenAI Key는 여기 두지 않음
├── client-tools/                    # 사용자에게 배포할 도구 (check-info.sh + README)
├── nginx/                           # TLS 단일 진입점 (자체서명 자동 생성)
├── openbao/                         # 시크릿 저장소 (init-keys.json은 오프라인 백업 필수)
├── litellm/config.yaml              # 모델 매핑 (user01~10 × gpt-4o/o3-mini = 20개)
├── scripts/
│   ├── set-openai-key.sh            # ★ 관리자가 OpenAI Key를 OpenBao에 직접 적재
│   ├── 01-init-openbao.sh / 02-load-secrets.sh / 03-register-users.sh / 04-health-check.sh
│   └── sample-keys.txt              # 발급된 Virtual Key (자동 생성, gitignore)
├── tests/                           # 6개 통합 테스트 + test-all.sh
└── docs/
    ├── guides/
    │   ├── admin-guide.md           # 관리자 운영 안내
    │   └── user-guide.md            # 사용자 사용 안내
    ├── operations/
    │   └── secrets-and-config.md    # 비밀 파일 / 백업 상세
    └── design/
        ├── D1-system-requirements.md   # v1 설계 (Virtual Key 단독)
        ├── D2-system-requirements.md   # v2 설계 (SSO 통합)
        └── D3-implementation-plan.md   # PoC 구현 플랜
```

---

## 아키텍처 요약

```
[브라우저/Codex]──HTTPS──►[Nginx :443]──proxy_pass──►[LiteLLM :4000]
                                                          │
                                              ┌───────────┴───────────┐
                                              ▼                       ▼
                                       [PostgreSQL :5432]      [OpenBao :8200]
                                       Users/Keys/Logs         User OpenAI Keys
```

- 인증: Virtual Key(`sk-vk-…`, 24h TTL) → LiteLLM이 슬롯에 매핑된 OpenAI Key로 치환 후 OpenAI 호출
- 사용자 간 격리: `userNN-gpt-4o` 모델은 `userNN`만 호출 가능 (RBAC + 모델 화이트리스트)
- 관리자 UI: Master Key 단독 로그인, 전체 prompt/spend Logs 열람 (90d 보존)

---

## 자주 쓰는 명령

| 작업 | 명령 |
|------|------|
| 정지 (데이터 보존) | `./stop.sh` |
| 완전 초기화 | `./reset.sh` |
| 로그 보기 | `docker compose logs -f litellm` |
| 새 Virtual Key 일괄 재발급 | `./start.sh` (멱등 — 매일 1회 권장) |
| 통합 테스트만 재실행 | `./tests/test-all.sh` |

---

## 트러블슈팅 (요약)

| 증상 | 해결 |
|------|------|
| `Docker daemon is not running` | `sudo service docker start` 또는 Docker Desktop 시작 |
| Phase 5b LiteLLM ready 시간 초과 | `docker compose logs litellm` (첫 실행은 30~60초 소요) |
| 사용자 401 | Virtual Key 24h 만료 — `./start.sh` 재실행 후 새 키 배포 |
| OpenAI 401 | OpenBao 슬롯이 placeholder — `./scripts/set-openai-key.sh userNN sk-proj-...` 후 `./start.sh` |
| OpenBao Sealed | `./openbao/unseal.sh` |

전체 표 → [admin-guide.md §13](docs/guides/admin-guide.md).

---

## 참고 문서

- 운영: [docs/guides/admin-guide.md](docs/guides/admin-guide.md), [docs/operations/secrets-and-config.md](docs/operations/secrets-and-config.md)
- 사용: [docs/guides/user-guide.md](docs/guides/user-guide.md), [client-tools/README.md](client-tools/README.md)
- 설계: [D1](docs/design/D1-system-requirements.md) · [D2](docs/design/D2-system-requirements.md) · [D3](docs/design/D3-implementation-plan.md) · [D4 사례 갭 분석/개선 설계](docs/design/D4-reference-gap-analysis.md)
