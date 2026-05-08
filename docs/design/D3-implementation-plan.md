# D3 — 상세 구현 플랜

> D1, D2를 토대로 한 PoC 구현 계획. 이 문서를 따르면 단일 명령(`./start.sh`)으로 전체 스택이 기동되고 검증까지 자동 수행된다.

## 1. 결과물 트리

```
llm-access-gateway/
├── .env                           # 환경변수 (start.sh가 자동 생성, 600 권한)
├── .env.example                   # 템플릿
├── .gitignore
├── docker-compose.yml             # 4개 서비스: openbao / postgres / litellm / nginx
├── start.sh                       # 단일 진입점 — 전체 부트스트랩 + 검증
├── stop.sh                        # 전체 정지 (데이터 보존)
├── reset.sh                       # 전체 정지 + 데이터 삭제 (재초기화용)
├── docs/design/
│   ├── D1-system-requirements.md
│   ├── D2-system-requirements.md
│   └── D3-implementation-plan.md  (본 문서)
├── nginx/
│   ├── nginx.conf                 # TLS 단일 진입점
│   └── certs/                     # 자체서명 인증서 (start.sh가 생성)
├── openbao/
│   ├── config/openbao.hcl
│   ├── data/                      # 시크릿 영속 저장 (gitignore)
│   ├── logs/                      # 감사 로그
│   ├── init-keys.json             # Unseal/Root 키 (gitignore, 600)
│   └── unseal.sh                  # 재기동용 unseal 스크립트
├── litellm/
│   └── config.yaml                # 모델 매핑 + 일반 설정
├── scripts/
│   ├── 01-init-openbao.sh         # OpenBao 초기화/Unseal/KV 활성화 (멱등)
│   ├── 02-load-secrets.sh         # 10명 OpenAI Key 적재 (placeholder)
│   ├── 03-register-users.sh       # LiteLLM /user/new + /key/generate
│   ├── 04-health-check.sh         # 기동 후 Liveness 체크
│   └── sample-keys.txt            # 발급된 Virtual Key 목록 (start.sh가 생성)
└── tests/
    ├── test-all.sh                # 전체 테스트 러너
    ├── 01-test-health.sh          # /health, HTTPS, redirect
    ├── 02-test-models.sh          # 모델 20개 노출 확인
    ├── 03-test-key-generation.sh  # Virtual Key 발급 + 24h TTL
    ├── 04-test-isolation.sh       # 사용자 간 모델 격리
    ├── 05-test-vault-integration.sh  # OpenBao ↔ LiteLLM 연동
    └── 06-test-rbac.sh            # Internal User vs Master Key 권한 차이
```

## 2. start.sh 실행 흐름

```
[Phase 0] Pre-flight 검증
  └─ docker, docker compose, curl, openssl 가용성 확인
  └─ jq는 OpenBao 컨테이너 내부에서 사용하거나 python3로 fallback

[Phase 1] Bootstrap (최초 실행만)
  ├─ 디렉토리 생성: openbao/{data,logs,config}, nginx/certs
  ├─ .env 생성 (랜덤 Master Key, PG 비밀번호)
  └─ TLS 자체서명 인증서 발급

[Phase 2] OpenBao 기동 (단독)
  └─ docker compose up -d openbao

[Phase 3] OpenBao 초기화 + Unseal (멱등)
  ├─ status 조회 → 미초기화 시 init (5/3 Shamir)
  ├─ init-keys.json 저장 (600)
  ├─ Sealed=true 시 3개 키로 unseal
  └─ Root Token을 .env의 OPENBAO_ROOT_TOKEN에 기록

[Phase 4] KV 시크릿 엔진 활성화 + 사용자 키 적재
  ├─ secret/ 경로에 KV v2 활성화 (멱등)
  └─ USER01_OPENAI_KEY ~ USER10_OPENAI_KEY 10개 placeholder 키 저장

[Phase 5] PostgreSQL + LiteLLM + Nginx 기동
  └─ docker compose up -d postgres litellm nginx
  └─ LiteLLM /health/readiness 까지 최대 120초 대기

[Phase 6] 사용자 사전등록
  ├─ alice@local ~ jack@local 10명 → user01~user10 슬롯 매핑
  ├─ admin@local 1명 → proxy_admin
  └─ 각 사용자별 Virtual Key 발급 (24h TTL)
  └─ 결과를 scripts/sample-keys.txt에 저장

[Phase 7] 검증 테스트
  └─ tests/test-all.sh 실행 (6개 테스트)

[Phase 8] 결과 출력
  └─ UI URL, Master Key, Virtual Key 위치, 다음 단계 안내
```

## 3. 핵심 설계 결정

### 3.1 PoC 단순화 사항

본 PoC 구현은 D2의 시나리오 중 다음을 의도적으로 단순화한다.

| 항목 | D2 설계 | D3 PoC 구현 | 이유 |
|------|--------|------------|------|
| SSO IdP | 사내 OIDC IdP 필수 | env 자리만 비워둠 (비활성) | 외부 IdP 의존 없이 자기완결적 검증 가능 |
| 사용자 인증 | SSO + Virtual Key | Virtual Key 단독 (Master Key로 발급) | D1 흐름 그대로 동작 |
| OpenAI Key | 실 키 10개 필요 | Placeholder 형식 키 | 인증/라우팅/RBAC 검증은 OpenAI 호출 전에 끝남 |
| TLS 인증서 | 사내 CA / Let's Encrypt | 자체서명 (`-k` 필요) | 도메인 등록 없이 동작 |

### 3.2 SSO 활성화는 어떻게?

`.env`의 다음 항목을 채우면 된다 (LiteLLM 재시작 필요).

```
GENERIC_CLIENT_ID=...
GENERIC_CLIENT_SECRET=...
GENERIC_AUTHORIZATION_ENDPOINT=...
GENERIC_TOKEN_ENDPOINT=...
GENERIC_USERINFO_ENDPOINT=...
```

LiteLLM은 이 값들이 모두 설정되면 자동으로 `/sso/key/generate` 엔드포인트를 활성화한다.

### 3.3 멱등성

- `start.sh`는 여러 번 실행해도 안전 — OpenBao status 확인, 사용자 존재 확인 등으로 중복 작업 방지
- `reset.sh`는 모든 데이터를 삭제하고 처음부터 재초기화 (PoC 반복 검증용)

### 3.4 OpenBao ↔ LiteLLM 연동 메커니즘

LiteLLM `model_list`의 `api_key: "os.environ/USER01_OPENAI_KEY"` 표기는 다음과 같이 해석된다.

1. 컨테이너 OS 환경변수 `USER01_OPENAI_KEY` 조회
2. 없으면 OpenBao의 `secret/litellm/USER01_OPENAI_KEY`의 `key` 필드 조회

PoC에서는 **컨테이너 env에 의도적으로 넣지 않고 OpenBao에만 저장**하여 vault 연동을 강제 검증한다.

## 4. 검증 전략

### 4.1 자동 검증 항목 (tests/test-all.sh)

| # | 테스트 | 검증 내용 |
|---|--------|----------|
| 01 | health | `/health` 200 응답, HTTP→HTTPS 301, TLS handshake |
| 02 | models | `/v1/models`로 20개 모델 노출 (user01~user10 × 2) |
| 03 | key-gen | Master Key로 Virtual Key 발급 → expires가 24h 후 ISO 시각 |
| 04 | isolation | user01 Key로 user02 모델 호출 시 401/403 거부 |
| 05 | vault | LiteLLM이 OpenBao에서 키를 읽어 모델 로드 성공 (모델 목록에 표시되는 것 자체가 vault 연동 성공의 증거) |
| 06 | rbac | Internal User Key는 `/key/generate` 호출 거부, Master Key는 허용 |

### 4.2 수동 검증 (Codex CLI E2E)

`docs/manual-verification.md`에 정리. PoC 구현 자동화 범위 외.

### 4.3 SSO 검증 (별도)

실 IdP 연결 후에만 검증 가능. D2 §17.1, §17.4, §17.6 시나리오 참조.

## 5. 구현 순서

1. ✅ 모든 파일 작성 (위 트리 순서대로)
2. ✅ `start.sh` 실행 권한 부여
3. ✅ `./start.sh` 실행
4. ✅ 결과 확인 → 실패 시 로그 분석 → 수정 후 재실행
5. ✅ 수동 점검 (UI 접속, curl로 chat completions 시도)

## 6. 알려진 제약사항

| 제약 | 영향 | 대응 |
|------|------|------|
| Placeholder OpenAI Key 사용 | 실제 chat completions은 OpenAI 401 반환 | 실 키로 교체 후 재기동 필요. 인증/라우팅 테스트는 영향 없음 |
| 자체서명 TLS | 브라우저 경고, curl `-k` 필요 | 운영 시 사내 CA 또는 Let's Encrypt로 교체 |
| OpenBao 수동 Unseal | 컨테이너 재기동 시 sealed 상태 복귀 | `start.sh`가 자동으로 unseal 처리. 운영 시 KMS Auto Unseal 권장 |
| LiteLLM 일부 설정 키의 버전 호환 | `enforce_key_generate_params` 등 | 미적용 시 UI Settings에서 런타임 변경. 실 동작 확인 필요 |

---

이 플랜대로 구현하면 단일 명령으로 PoC 검증이 완료된다.
