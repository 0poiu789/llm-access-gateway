# LLM Access Gateway

OpenBao + LiteLLM Proxy 기반 사용자별 OpenAI Key 격리 LLM 게이트웨이 (PoC).

## 빠른 시작

```bash
./start.sh
```

이 한 줄로 다음이 자동 수행된다:

1. `.env` 자동 생성 (랜덤 Master Key, PG 비밀번호)
2. 자체서명 TLS 인증서 발급
3. Docker Compose로 4개 서비스 기동 (OpenBao, PostgreSQL, LiteLLM, Nginx)
4. OpenBao 초기화 + Unseal + KV 활성화
5. 사용자 OpenAI Key 10개 적재 (placeholder)
6. LiteLLM에 사용자 10명 + 관리자 1명 사전등록
7. 각 사용자별 24h TTL Virtual Key 발급
8. 6개 통합 검증 테스트 실행
9. 결과 요약 출력 (UI URL, Master Key, Virtual Key 위치)

## 사전 요구사항

- Docker 데몬 실행 중 (`docker info` 성공해야 함)
- `docker compose` v2
- `curl`, `openssl`, `python3` (시스템 기본 제공)

WSL2에서 Docker Desktop을 사용하려면 Docker Desktop 설정 → Resources → WSL Integration에서 해당 배포판을 활성화하라. 데몬이 없으면 `start.sh`의 Phase 0에서 명확한 에러로 중단된다.

## 디렉토리 구조

```
.
├── docs/design/
│   ├── D1-system-requirements.md     # v1 설계 (Virtual Key 단독 인증)
│   ├── D2-system-requirements.md     # v2 설계 (SSO 통합)
│   └── D3-implementation-plan.md     # 본 PoC 구현 플랜
├── docker-compose.yml
├── .env.example                      # 템플릿
├── start.sh                          # 단일 진입점
├── stop.sh                           # 정지 (데이터 보존)
├── reset.sh                          # 초기화 (데이터 삭제)
├── nginx/
│   ├── nginx.conf                    # TLS 단일 진입점, RBAC는 LiteLLM이 담당
│   └── certs/                        # 자체서명 인증서 (자동 생성)
├── openbao/
│   ├── config/openbao.hcl
│   └── unseal.sh                     # 재기동 시 unseal
├── litellm/
│   └── config.yaml                   # 모델 매핑 + 24h TTL + Vault 연동
├── scripts/
│   ├── 01-init-openbao.sh            # OpenBao 초기화 (멱등)
│   ├── 02-load-secrets.sh            # 사용자 OpenAI Key 적재
│   ├── 03-register-users.sh          # 사용자 사전등록 + Virtual Key 발급
│   ├── 04-health-check.sh            # LiteLLM readiness 대기
│   └── sample-keys.txt               # 발급된 Virtual Key (자동 생성)
└── tests/
    ├── test-all.sh                   # 전체 테스트 러너
    ├── 01-test-health.sh             # /health, HTTPS, redirect
    ├── 02-test-models.sh             # 20개 모델 노출
    ├── 03-test-key-generation.sh     # Virtual Key + 24h TTL
    ├── 04-test-isolation.sh          # 사용자 간 모델 격리
    ├── 05-test-vault-integration.sh  # OpenBao ↔ LiteLLM
    └── 06-test-rbac.sh               # Master vs Internal User 권한
```

## 아키텍처 요약

```
[브라우저/Codex]──HTTPS──►[Nginx :443]──proxy_pass──►[LiteLLM :4000]
                                                          │
                                              ┌───────────┴───────────┐
                                              ▼                       ▼
                                       [PostgreSQL :5432]      [OpenBao :8200]
                                       Users/Keys/Logs         User OpenAI Keys
```

## 사용자 시나리오

### 일반 사용자
1. 브라우저로 `https://localhost/ui` 접속
2. (PoC) Master Key로 로그인 — 본인의 Virtual Key 조회/Regenerate
3. Codex CLI에 Virtual Key 입력하여 사용
4. 24시간 후 만료 → UI 재방문하여 새 Key 발급

### 관리자
1. `https://localhost/ui`에 Master Key로 로그인
2. Logs 탭에서 전체 사용자 요청/응답 열람
3. Internal Users 탭에서 사용자 관리

### Codex CLI 설정 예시

```bash
# ~/.codex/config.toml
openai_base_url = "https://localhost/v1"
model = "user01-gpt-4o"
approval_mode = "suggest"

# 환경변수
export OPENAI_API_KEY="sk-vk-..."  # scripts/sample-keys.txt에서 복사
```

## SSO 활성화 (선택)

`.env`의 다음 항목을 사내 IdP 값으로 채우고 `docker compose restart litellm`:

```
GENERIC_CLIENT_ID=...
GENERIC_CLIENT_SECRET=...
GENERIC_AUTHORIZATION_ENDPOINT=...
GENERIC_TOKEN_ENDPOINT=...
GENERIC_USERINFO_ENDPOINT=...
ALLOWED_USER_EMAIL_DOMAINS=company.com
```

자세한 IdP 설정은 [D2-system-requirements.md §9](docs/design/D2-system-requirements.md) 참조.

## 실 운영 전 필수 변경

1. **Placeholder OpenAI Key를 실 키로 교체**:
   ```bash
   ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('openbao/init-keys.json'))['root_token'])")
   docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
     bao kv put secret/litellm/USER01_OPENAI_KEY key="sk-proj-real-key"
   docker compose restart litellm
   ```

2. **`init-keys.json` 오프라인 백업 후 서버에서 삭제** (분실 시 복구 불가)

3. **자체서명 TLS → 사내 CA 또는 Let's Encrypt로 교체**

4. **방화벽에서 80, 443 외 포트 차단** (4000, 5432, 8200은 외부 노출 안 됨)

자세한 보안 체크리스트는 [D2 §20](docs/design/D2-system-requirements.md#20-보안-체크리스트) 참조.

## 트러블슈팅

| 증상 | 원인 / 해결 |
|------|------------|
| `Docker daemon is not running` | `sudo service docker start` 또는 Docker Desktop 시작 |
| `Phase 5b` LiteLLM ready 시간 초과 | `docker compose logs litellm` 로 원인 분석. PostgreSQL 마이그레이션이 처음엔 30~60초 걸릴 수 있음 |
| 테스트 04 (isolation) 실패 | `register-users.sh`가 정상 실행되었는지 `scripts/sample-keys.txt` 확인 |
| 테스트 05 (vault) 실패 | OpenBao Sealed 상태일 수 있음 → `./openbao/unseal.sh` |
| Codex CLI 401 | Virtual Key 만료 (24h) — UI 재방문하여 Regenerate |

## 참고

- [D1 — v1 설계](docs/design/D1-system-requirements.md): Virtual Key 단독 인증 모델
- [D2 — v2 설계](docs/design/D2-system-requirements.md): SSO 통합 모델 (PoC 기반)
- [D3 — 구현 플랜](docs/design/D3-implementation-plan.md): 본 PoC 구현 계획
