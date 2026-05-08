# D2 — 시스템 요구사항 v2 (SSO 통합)

## 목차

- [0. 문서 정보](#0-문서-정보)
- [1. 분석 — D1의 한계와 v2 동기](#1-분석--d1의-한계와-v2-동기)
- [2. 사용자 시나리오](#2-사용자-시나리오)
- [3. 요구사항 v2](#3-요구사항-v2)
- [4. 시스템 아키텍처](#4-시스템-아키텍처)
- [5. 사용자 매핑 설계 — 사전등록 방식](#5-사용자-매핑-설계--사전등록-방식)
- [6. SSO 통합 설계](#6-sso-통합-설계)
- [7. Virtual Key TTL 24시간 설계](#7-virtual-key-ttl-24시간-설계)
- [8. UI/UX 결정 — LiteLLM 기본 UI 사용](#8-uiux-결정--litellm-기본-ui-사용)
- [9. Phase 1 — IdP 사전 설정](#9-phase-1--idp-사전-설정)
- [10. Phase 2 — 디렉토리 및 환경변수](#10-phase-2--디렉토리-및-환경변수)
- [11. Phase 3 — Nginx 단일 진입점 구성](#11-phase-3--nginx-단일-진입점-구성)
- [12. Phase 4 — Docker Compose 구성](#12-phase-4--docker-compose-구성)
- [13. Phase 5 — OpenBao 초기화 및 사용자 OpenAI Key 저장](#13-phase-5--openbao-초기화-및-사용자-openai-key-저장)
- [14. Phase 6 — LiteLLM 설정 (모델 매핑 + SSO + TTL)](#14-phase-6--litellm-설정-모델-매핑--sso--ttl)
- [15. Phase 7 — 시스템 기동](#15-phase-7--시스템-기동)
- [16. Phase 8 — 사용자 사전등록](#16-phase-8--사용자-사전등록)
- [17. Phase 9 — 검증 시나리오](#17-phase-9--검증-시나리오)
- [18. 사용자 가이드 (배포용)](#18-사용자-가이드-배포용)
- [19. 운영 가이드](#19-운영-가이드)
- [20. 보안 체크리스트](#20-보안-체크리스트)
- [21. 트러블슈팅](#21-트러블슈팅)
- [22. D1 대비 변경 요약](#22-d1-대비-변경-요약)
- [23. 참고자료](#23-참고자료)

---

# 0. 문서 정보

| 항목 | 내용 |
|------|------|
| 문서 ID | D2 |
| 버전 | v2.0 |
| 단계 | PoC |
| 기반 문서 | [D1-system-requirements.md](D1-system-requirements.md) |
| 변경 핵심 | SSO 통합, 단일 진입점, Virtual Key 24h TTL, 사용자 사전등록 |
| 구현 가능성 | 본 문서만으로 즉시 구현 착수 가능 |

---

# 1. 분석 — D1의 한계와 v2 동기

## 1.1 D1의 사용자/관리자 시나리오 한계

D1은 다음과 같은 운영 부담을 갖는다.

| 항목 | D1의 처리 방식 | 발생 문제 |
|------|--------------|----------|
| **사용자 인증** | 없음 — Virtual Key 보유 자체가 인증 | Key 유출 시 누구나 사용 가능, 회수 어려움 |
| **권한 부여** | 관리자가 curl로 Key 발급 → out-of-band(이메일/메신저) 전달 | 수동 작업, 감사 추적 부재 |
| **권한 회수** | 관리자가 `/key/block` 호출 | 직원 퇴사 시 누락 가능, 자동화 부재 |
| **사용자 페이지** | 없음 | 사용자가 본인 사용량/Key를 조회할 표준 경로 없음 (curl만 가능) |
| **관리자 접근 제한** | IP 화이트리스트(8443 포트) | 재택/외근 등 IP 변동 시 접근 불가 |
| **Key 수명** | 무제한 | 분실/유출 위험 누적, 정기 교체 자동화 없음 |

## 1.2 v2가 해결하려는 핵심

1. **사내 SSO 인증을 거친 사용자에게만 게이트웨이 접근 권한을 부여**한다. IdP 그룹 멤버십이 진실 공급원이 된다.
2. **사용자/관리자 모두 단일 URL로 진입**하며, 역할 분기는 LiteLLM UI 내부 RBAC가 처리한다.
3. **Virtual Key는 24시간 후 자동 만료**되어 분실/유출 위험 노출 시간을 짧게 유지한다. 사용자는 매일 UI에 재로그인하여 새 Key를 발급받는다.
4. **사용자별 OpenAI API Key 분리(D1 요구사항 #2)는 그대로 유지**한다. SSO 이메일과 사전등록된 사용자 슬롯(user01~user10)을 매칭하는 방식으로 매핑.

## 1.3 v2가 의도적으로 배제하는 것

- **자체 대시보드 신규 개발**: PoC 단계에서는 LiteLLM 기본 UI로 충분 (§8 참조).
- **CLI(Codex)에 대한 SSO 강제**: Codex CLI는 Bearer 토큰만 지원하므로 Virtual Key 인증을 그대로 사용. SSO는 UI 진입과 Key 발급/조회 시점에만 적용.
- **자동 Key Rotation 스케줄러**: 사용자가 UI 재방문하여 직접 Regenerate. 자동 발급 cron은 v3 이후로 보류.

---

# 2. 사용자 시나리오

## 2.1 일반 사용자 (개발자)

```
[1] 브라우저로 https://llm-gateway.<사내도메인>/ 접속
[2] LiteLLM UI의 "Sign in with SSO" 클릭
[3] 사내 IdP로 리다이렉트되어 인증 (사번/비밀번호 + 2FA)
[4] IdP가 그룹 클레임을 LiteLLM에 전달
     - "llm-gateway-users" 그룹 비멤버  → 접근 거부
     - 멤버 + 사전등록된 이메일        → UI 진입
[5] UI에서:
     - "Virtual Keys" 탭 → 본인의 Key 목록 + Regenerate 버튼
     - "Usage" 탭        → 본인의 spend/요청 통계
     - 발급된 Key 값을 클립보드에 복사 (24h 유효)
[6] (최초 1회) Codex CLI 설정:
     - ~/.codex/config.toml 에 LiteLLM URL 입력
     - 환경변수 OPENAI_API_KEY 에 Virtual Key 입력
[7] Codex CLI로 본인의 모델(예: user03-gpt-4o) 호출
[8] 24h 후 Key 만료 → [1]~[5] 반복 (Regenerate만 클릭)
```

## 2.2 관리자

```
[1] 브라우저로 https://llm-gateway.<사내도메인>/ 접속
[2] SSO 인증 (llm-gateway-admins 그룹 멤버)
[3] LiteLLM UI 진입 (Proxy Admin 역할로 자동 인식)
[4] UI에서:
     - "Logs" 탭          → 전 사용자 요청/응답 전문, 모델, 토큰, 비용
     - "Usage" 탭         → 전체 spend 대시보드
     - "Internal Users"   → 사용자 추가/모델 매핑/차단
     - "Models"           → 모델 항목 관리 (사용자-OpenAI Key 매핑 변경)
     - "Settings"         → SSO 설정, Key TTL, 로그 보관 정책 변경
```

## 2.3 비허용 사용자 (그룹 비멤버)

```
[1] https://llm-gateway.<사내도메인>/ 접속
[2] SSO 인증 시도
[3] IdP는 인증 통과 → LiteLLM 콜백
[4] LiteLLM이 그룹 클레임 검증 → llm-gateway-users 비멤버
[5] 접근 거부 화면 ("권한이 없습니다. 관리자에게 문의")
```

---

# 3. 요구사항 v2

| # | 요구사항 | 구현 방법 | D1 대비 |
|---|---------|----------|--------|
| 1 | 사내 SSO로 인증된 사용자만 게이트웨이 접근 | IdP OIDC + LiteLLM SSO + 그룹 클레임 검증 | **신규** |
| 2 | 권한이 있는 사용자만 UI 진입 가능 | IdP `llm-gateway-users` 그룹 멤버십 체크 | **신규** |
| 3 | 사용자는 UI에서 본인의 Virtual Key를 발급/조회/Regenerate | LiteLLM UI "Virtual Keys" 탭 (Internal User 권한) | **변경** (D1: 관리자가 발급해 전달) |
| 4 | 사용자는 UI에서 본인의 사용내역(spend, 모델, 요청 수) 확인 | LiteLLM UI "Usage" 탭 | **변경** (D1: curl만 가능) |
| 5 | 각 사용자는 고유한 OpenAI API Key에 매핑 | 사용자별 model_name + OpenBao 분리 저장 (D1과 동일) | 유지 |
| 6 | Virtual Key는 24시간 후 자동 만료 | LiteLLM `default_key_duration: "24h"` | **신규** |
| 7 | 관리자는 UI에서 전 사용자의 입출력 로그 열람 | `store_prompts_in_spend_logs: true` + Admin UI Logs 탭 | 유지 |
| 8 | 관리자는 UI에서 사용자 추가/차단/모델 변경 | LiteLLM UI "Internal Users", "Models" 탭 | **변경** (D1: curl만 가능) |
| 9 | 일반 사용자는 타인의 데이터/로그 열람 불가 | LiteLLM RBAC (Internal User 역할) | 유지 |
| 10 | Codex CLI는 변경 없이 Virtual Key로 동작 | OpenAI 호환 엔드포인트 + Bearer 인증 | 유지 |
| 11 | 권한 회수는 IdP에서 그룹 제거만으로 처리 | SSO 재인증 시 그룹 클레임으로 차단 | **신규** |
| 12 | 모든 트래픽은 HTTPS | Nginx TLS | **강화** (D1: HTTP) |

---

# 4. 시스템 아키텍처

## 4.1 구성도

```
                                  ┌─────────────────┐
                                  │   사내 IdP      │
                                  │ (OIDC Provider) │
                                  │  Azure AD /     │
                                  │  Keycloak /     │
                                  │  Okta 등        │
                                  └────────▲────────┘
                                           │ OIDC
                                           │ (groups, email)
                                           │
[사내 PC]                                   │
   │                                       │
   │ ① 브라우저로 UI 접속 ──HTTPS─────►  ┌─┴────────────┐
   │                                      │              │
   │                                      │   Nginx :443 │
   │ ② Codex CLI ────HTTPS + Bearer───►   │ (TLS, 단일   │
   │                                      │  진입점)     │
   │                                      └──────┬───────┘
   │                                             │
   │                                             │ proxy_pass
   │                                             ▼
   │                                      ┌──────────────┐
   │                                      │  LiteLLM     │
   │                                      │  Proxy :4000 │
   │                                      │              │
   │                                      │  - SSO 처리  │
   │                                      │  - RBAC      │
   │                                      │  - Key TTL   │
   │                                      └──┬───────┬───┘
   │                                         │       │
   │                       ┌─────────────────┘       └────────────────┐
   │                       ▼                                          ▼
   │                ┌──────────────┐                          ┌───────────────┐
   │                │  PostgreSQL  │                          │   OpenBao     │
   │                │  - Users     │                          │   - User01~10 │
   │                │  - Keys      │                          │     OpenAI    │
   │                │  - SpendLogs │                          │     API Keys  │
   │                │  - Prompts   │                          └───────────────┘
   │                └──────────────┘                                  │
   │                                                                  ▼
   │                                                          ┌───────────────┐
   └─────► (응답 스트리밍) ◄────────────────────────────────── │  OpenAI API   │
                                                              └───────────────┘
```

## 4.2 구성요소

| 구성요소 | 역할 | 포트 (외부) | 포트 (내부) | Docker 이미지 |
|---------|------|------------|------------|--------------|
| **Nginx** | TLS 종단, 단일 리버스 프록시 | 80→443 리다이렉트, 443 (HTTPS) | — | `nginx:alpine` |
| **LiteLLM Proxy** | LLM 게이트웨이, SSO, RBAC, Key 관리, UI | — | 4000 | `docker.litellm.ai/berriai/litellm-database:main-latest` |
| **PostgreSQL** | 사용자/Key/Spend/Prompt 저장 | — | 5432 | `postgres:16-alpine` |
| **OpenBao** | 사용자별 OpenAI Key 시크릿 저장 | — | 8200 | `openbao/openbao:latest` |
| **사내 IdP** | OIDC 공급자 (외부 시스템) | — | — | (별도 운영) |

---

# 5. 사용자 매핑 설계 — 사전등록 방식

## 5.1 매핑 모델

| 항목 | 값 |
|------|-----|
| 매핑 키 | SSO 이메일 (예: `alice@company.com`) |
| 매핑 슬롯 | `user01` ~ `user10` (LiteLLM model_name 접두어로 사용) |
| 매핑 변경 권한 | 관리자만 (LiteLLM UI Internal Users 탭) |
| 신규 사용자 추가 절차 | (1) IdP 그룹 등록 → (2) `/user/new` API로 LiteLLM에 사전등록 |

## 5.2 매핑 테이블 (예시 — 실 운영 시 채울 것)

| 슬롯 | SSO 이메일 | 이름 | 허용 모델 | OpenBao 시크릿 경로 |
|------|----------|------|---------|-------------------|
| user01 | alice@company.com | 홍길동 | `user01-gpt-4o`, `user01-o3-mini` | `secret/litellm/USER01_OPENAI_KEY` |
| user02 | bob@company.com | 김철수 | `user02-gpt-4o`, `user02-o3-mini` | `secret/litellm/USER02_OPENAI_KEY` |
| user03 | carol@company.com | 이영희 | `user03-gpt-4o`, `user03-o3-mini` | `secret/litellm/USER03_OPENAI_KEY` |
| user04 | dave@company.com | 박민수 | `user04-gpt-4o`, `user04-o3-mini` | `secret/litellm/USER04_OPENAI_KEY` |
| user05 | eve@company.com | 최지은 | `user05-gpt-4o`, `user05-o3-mini` | `secret/litellm/USER05_OPENAI_KEY` |
| user06 | frank@company.com | 정서연 | `user06-gpt-4o`, `user06-o3-mini` | `secret/litellm/USER06_OPENAI_KEY` |
| user07 | grace@company.com | 강도현 | `user07-gpt-4o`, `user07-o3-mini` | `secret/litellm/USER07_OPENAI_KEY` |
| user08 | henry@company.com | 윤하은 | `user08-gpt-4o`, `user08-o3-mini` | `secret/litellm/USER08_OPENAI_KEY` |
| user09 | ivy@company.com | 장현우 | `user09-gpt-4o`, `user09-o3-mini` | `secret/litellm/USER09_OPENAI_KEY` |
| user10 | jack@company.com | 한소율 | `user10-gpt-4o`, `user10-o3-mini` | `secret/litellm/USER10_OPENAI_KEY` |

## 5.3 매핑 적용 메커니즘

LiteLLM `/user/new` API로 SSO 이메일을 `user_email` 필드에 사전등록한다. SSO 첫 로그인 시 LiteLLM은 이메일로 기존 사용자를 매칭하고, 사전 지정된 `models` 목록(예: `[user03-gpt-4o, user03-o3-mini]`)을 사용자의 권한으로 적용한다. 이후 사용자가 UI에서 발급하는 Virtual Key는 자동으로 이 모델 목록을 상속받아 다른 사용자의 모델에 접근할 수 없다.

---

# 6. SSO 통합 설계

## 6.1 IdP 측 요구사항

다음 IdP가 모두 OIDC를 지원하므로 본 설계는 IdP 종류에 무관하게 적용 가능하다: Azure AD, Keycloak, Okta, Google Workspace, Auth0.

**IdP에서 사전 준비할 것:**

1. **OIDC 클라이언트 등록**
   - Application Type: Web
   - Redirect URI: `https://llm-gateway.<사내도메인>/sso/callback`
   - 응답 타입: `code` (Authorization Code Flow)
   - 클라이언트 ID 및 클라이언트 시크릿 발급
2. **그룹 정의**
   - `llm-gateway-users` — 일반 사용자 그룹
   - `llm-gateway-admins` — 관리자 그룹 (소수 인원)
3. **클레임 매핑 (id_token에 다음 클레임이 포함되도록 설정)**
   - `email` — 사용자 이메일 (LiteLLM 매칭 키)
   - `groups` — 그룹 이름 배열
   - `name`, `given_name`, `family_name` — 표시용

## 6.2 LiteLLM SSO 환경변수

LiteLLM은 OIDC를 Generic 어댑터로 지원한다. `.env`에 다음 항목을 추가한다.

```bash
# ── OIDC SSO ──
GENERIC_CLIENT_ID=<IdP에서 발급받은 클라이언트 ID>
GENERIC_CLIENT_SECRET=<IdP 클라이언트 시크릿>
GENERIC_AUTHORIZATION_ENDPOINT=https://idp.<사내도메인>/oauth/authorize
GENERIC_TOKEN_ENDPOINT=https://idp.<사내도메인>/oauth/token
GENERIC_USERINFO_ENDPOINT=https://idp.<사내도메인>/oauth/userinfo

# JWT/UserInfo 클레임 매핑
GENERIC_USER_ID_JWT_FIELD=sub
GENERIC_USER_EMAIL_JWT_FIELD=email
GENERIC_USER_FIRST_NAME_JWT_FIELD=given_name
GENERIC_USER_LAST_NAME_JWT_FIELD=family_name
GENERIC_USER_ROLE_JWT_FIELD=groups

# 도메인 화이트리스트 (이메일 도메인 검증)
ALLOWED_USER_EMAIL_DOMAINS=company.com

# UI 베이스 URL (SSO redirect 생성에 사용)
PROXY_BASE_URL=https://llm-gateway.<사내도메인>

# 신규 SSO 사용자 기본 역할 (사전등록자 외 자동 거부 효과)
DEFAULT_USER_ROLES_LITELLM_SSO=internal_user_viewer
```

## 6.3 그룹 → 역할 매핑

LiteLLM은 SSO 클레임의 그룹 값을 자체 역할로 매핑한다. `litellm/config.yaml`의 `general_settings`에 다음을 추가한다.

```yaml
general_settings:
  # ... 기존 설정 ...

  # SSO 그룹 → LiteLLM 역할 매핑
  litellm_jwtauth:
    admin_jwt_scope: "groups"
    admin_allowed_routes: ["/key/*", "/user/*", "/spend/*", "/global/*", "/model/*"]
    team_id_jwt_field: null
    user_id_jwt_field: "email"
    user_email_jwt_field: "email"
    roles_jwt_field: "groups"
    role_mappings:
      llm-gateway-admins: "proxy_admin"
      llm-gateway-users: "internal_user"
```

> ⚠️ **검증 노트**: LiteLLM SSO의 정확한 환경변수 키와 `role_mappings` 스키마는 LiteLLM 버전에 따라 다를 수 있다. 구현 착수 시 LiteLLM 공식 문서의 [SSO Setup](https://docs.litellm.ai/docs/proxy/ui#setup-sso-jwt-auth) 페이지로 최신 키 이름을 확인할 것. 본 문서의 키 이름은 LiteLLM v1.x 기준이다.

## 6.4 권한 부여/회수 흐름

```
[권한 부여]
  관리자가 IdP에서 사용자를 llm-gateway-users 그룹에 추가
       │
       └─► LiteLLM에 /user/new API로 사전등록 (이메일 + 모델 슬롯)
       │
       └─► 사용자에게 https://llm-gateway.<도메인> URL 안내
              │
              └─► 사용자가 SSO 로그인 → UI 진입 → Key 발급

[권한 회수]
  관리자가 IdP에서 사용자를 그룹에서 제거
       │
       └─► 다음 SSO 인증 시도 시 LiteLLM이 그룹 클레임 검증 실패 → 거부
       │
       └─► (즉시 차단이 필요한 경우) LiteLLM UI에서 해당 사용자의 Key 일괄 차단
              + 기 발급된 Virtual Key는 24h 내 자동 만료
```

---

# 7. Virtual Key TTL 24시간 설계

## 7.1 TTL 적용 방식

LiteLLM은 Key 발급 시 `duration` 파라미터로 만료 시각을 설정한다. 사용자가 UI에서 직접 발급할 때도 동일하게 적용되도록 다음 두 가지 방어선을 둔다.

**1차 — 글로벌 default TTL** (litellm/config.yaml):

```yaml
general_settings:
  default_key_generate_params:
    duration: "24h"
```

**2차 — Key Generation 정책으로 명시 강제** (사용자가 임의 변경 불가):

```yaml
general_settings:
  key_generation_settings:
    require_team_id: false
    enforce_key_generate_params:
      duration:
        max: "24h"
        min: "1h"
```

> ⚠️ **검증 노트**: `enforce_key_generate_params` 키는 LiteLLM 최신 버전에서 지원되는지 확인 후 적용. 미지원 시 1차 default만으로도 사용자가 UI에서 24h를 임의로 변경하는 화면이 노출되지 않도록 UI Custom Settings에서 변경 권한을 제거하면 됨.

## 7.2 만료 후 동작

- Key가 만료된 상태에서 Codex CLI 호출 시: HTTP 401 반환 (`{"error": {"message": "API Key expired"}}`)
- 사용자는 UI에 재로그인하여 "Regenerate" 버튼 클릭 → 새 Key가 즉시 발급되고 기존 Key는 폐기 (회수 동작은 LiteLLM이 자동 처리)
- 만료된 Key의 사용량/로그 데이터는 PostgreSQL에 보존 (감사 추적용)

## 7.3 사용자 안내사항

- 매일 1회 UI 재방문 필요
- Codex CLI 작업 도중 401 발생 시: UI → Regenerate → 새 Key를 환경변수에 갱신 → 작업 재개
- 환경변수 갱신을 자동화하려면 사용자 본인의 셸 함수 추천 (§18.3 참고)

---

# 8. UI/UX 결정 — LiteLLM 기본 UI 사용

## 8.1 결정

**PoC 단계에서는 LiteLLM 기본 Admin UI(`/ui`)를 그대로 사용한다.** 자체 대시보드 개발은 v3 이후 필요성이 입증되면 착수한다.

## 8.2 LiteLLM UI가 시나리오를 충족하는 항목

| 시나리오 | LiteLLM UI 기본 기능 | 충족 여부 |
|---------|-------------------|----------|
| SSO 로그인 | OIDC/SAML 지원 | ✓ |
| 사용자별 Key 조회/발급/Regenerate | "Virtual Keys" 탭 (Internal User 권한) | ✓ |
| 사용자별 사용량 조회 | "Usage" 탭 (본인 데이터만 RBAC로 제한) | ✓ |
| 관리자: 전 사용자 로그 | "Logs" 탭 + `store_prompts_in_spend_logs` | ✓ |
| 관리자: 사용자 추가/차단 | "Internal Users" 탭 | ✓ |
| 관리자: 모델 매핑 변경 | "Models" 탭 | ✓ |
| 관리자: Spend 대시보드 | "Usage" 탭 (전체 뷰) | ✓ |

## 8.3 PoC에서 의도적으로 보류하는 갭

- 한글 UI (LiteLLM은 영어 전용) — 사내 사용자 영어 UI 학습 비용 감수
- 사내 브랜딩(로고, 컬러) — PoC 검증 후 v3에서 자체 UI로 분리 검토
- "당신은 user03 슬롯입니다" 등 매핑 정보 명시적 노출 — UI Logs/Models 탭에서 간접 확인 가능
- 감사 로그 시각화 (누가 언제 누구의 Key를 발급/회수) — DB SELECT 쿼리로 대체

## 8.4 자체 UI 개발 가능 여부 (참고)

LiteLLM의 모든 기능이 REST API로 노출되므로, 향후 자체 프론트엔드(Next.js 등)를 LiteLLM 위에 얹어 동일 기능 + 한글 UI/사내 브랜딩으로 재구현하는 것이 가능하다. v2(PoC)에서는 범위 외.

---

# 9. Phase 1 — IdP 사전 설정

> 본 단계는 IdP 운영 담당자(인프라팀/보안팀) 작업이다. 결과물 4개를 인계받아 후속 단계로 진행.

## 9.1 OIDC 클라이언트 등록

IdP 관리 콘솔에서:

1. 새 OIDC 애플리케이션 생성
2. 다음 값 입력:
   - **Application Name**: `LLM Access Gateway`
   - **Application Type**: Web Application
   - **Redirect URIs**:
     - `https://llm-gateway.<사내도메인>/sso/callback`
     - `https://llm-gateway.<사내도메인>/sso/key/callback` (LiteLLM SSO 콜백 변형)
   - **Logout URI**: `https://llm-gateway.<사내도메인>/`
   - **Token Endpoint Auth Method**: `client_secret_post`
   - **Grant Types**: Authorization Code
   - **Response Types**: `code`
   - **Scopes**: `openid email profile groups`
3. 저장 후 다음 4개 값 기록:
   - 클라이언트 ID
   - 클라이언트 시크릿
   - Authorization Endpoint URL
   - Token Endpoint URL
   - UserInfo Endpoint URL

## 9.2 그룹 생성 및 멤버 등록

```
IdP 그룹 콘솔에서:

1. 그룹 생성: llm-gateway-users
2. 그룹 생성: llm-gateway-admins
3. 사용자 추가:
   - llm-gateway-users : alice, bob, carol, dave, eve, frank, grace, henry, ivy, jack
   - llm-gateway-admins : (관리자 1~2명)
   ※ 관리자도 그룹 양쪽에 모두 등록 권장
4. 그룹 클레임이 id_token/userinfo에 포함되도록 매핑 설정
   - 클레임 이름: groups
   - 값: 그룹 이름 배열 (예: ["llm-gateway-users", "llm-gateway-admins"])
```

## 9.3 인계물

다음 4개 값을 운영팀에 전달:

| 항목 | 값 |
|------|---|
| Client ID | `(예: 12345678-abcd-...)` |
| Client Secret | `(예: secret_xxxxx)` |
| Authorization Endpoint | `https://idp.사내/oauth/authorize` |
| Token Endpoint | `https://idp.사내/oauth/token` |
| UserInfo Endpoint | `https://idp.사내/oauth/userinfo` |

---

# 10. Phase 2 — 디렉토리 및 환경변수

## 10.1 디렉토리 구조

```bash
mkdir -p ~/llm-gateway/{openbao/{config,data,logs},litellm,postgres,nginx/certs}
cd ~/llm-gateway
```

추가 디렉토리: `nginx/certs` (TLS 인증서 보관용)

## 10.2 .env 파일

```bash
cat > .env << 'EOF'
# ══════════════════════════════════════════════
# LLM Access Gateway v2 환경변수
# ══════════════════════════════════════════════

# ── PostgreSQL ──
POSTGRES_PASSWORD=Change_This_Strong_Password_123!

# ── LiteLLM ──
LITELLM_MASTER_KEY=sk-master-change-me-to-random-string
PROXY_BASE_URL=https://llm-gateway.company.com

# ── OpenBao (Phase 5에서 채움) ──
OPENBAO_ROOT_TOKEN=

# ── OIDC SSO (Phase 1 인계물 입력) ──
GENERIC_CLIENT_ID=<클라이언트ID>
GENERIC_CLIENT_SECRET=<클라이언트시크릿>
GENERIC_AUTHORIZATION_ENDPOINT=https://idp.company.com/oauth/authorize
GENERIC_TOKEN_ENDPOINT=https://idp.company.com/oauth/token
GENERIC_USERINFO_ENDPOINT=https://idp.company.com/oauth/userinfo

# OIDC 클레임 매핑
GENERIC_USER_ID_JWT_FIELD=sub
GENERIC_USER_EMAIL_JWT_FIELD=email
GENERIC_USER_FIRST_NAME_JWT_FIELD=given_name
GENERIC_USER_LAST_NAME_JWT_FIELD=family_name
GENERIC_USER_ROLE_JWT_FIELD=groups

# 도메인 화이트리스트
ALLOWED_USER_EMAIL_DOMAINS=company.com

# 신규 SSO 사용자 기본 역할 (사전등록자 외엔 권한 없음)
DEFAULT_USER_ROLES_LITELLM_SSO=internal_user_viewer
EOF

chmod 600 .env
```

## 10.3 OpenBao 설정 파일 (D1과 동일)

```bash
cat > openbao/config/openbao.hcl << 'EOF'
ui = true

storage "file" {
  path = "/openbao/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr = "http://0.0.0.0:8200"
default_lease_ttl = "168h"
max_lease_ttl    = "720h"
EOF
```

## 10.4 TLS 인증서 준비

PoC 단계에서는 자체 서명 인증서로 시작하고, 운영 단계에서 사내 CA 또는 Let's Encrypt로 교체.

```bash
# 자체 서명 인증서 생성 (PoC용)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout nginx/certs/server.key \
  -out nginx/certs/server.crt \
  -subj "/C=KR/ST=Seoul/L=Seoul/O=Company/OU=IT/CN=llm-gateway.company.com"

chmod 600 nginx/certs/server.key
```

---

# 11. Phase 3 — Nginx 단일 진입점 구성

## 11.1 설계 원칙

D1의 "포트 80(사용자) / 8443(관리자)" 분리 구조를 폐기하고, **단일 HTTPS 포트로 모든 트래픽을 수용**한다. 권한 분리는 LiteLLM UI 내부 RBAC가 담당한다.

## 11.2 nginx/nginx.conf

```bash
cat > nginx/nginx.conf << 'NGINX'
worker_processes auto;
events { worker_connections 1024; }

http {
    upstream litellm_backend {
        server litellm:4000;
    }

    # ── HTTP → HTTPS 리다이렉트 ──
    server {
        listen 80;
        server_name _;
        return 301 https://$host$request_uri;
    }

    # ── HTTPS 단일 진입점 ──
    server {
        listen 443 ssl http2;
        server_name _;

        ssl_certificate     /etc/nginx/certs/server.crt;
        ssl_certificate_key /etc/nginx/certs/server.key;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;
        ssl_session_timeout 1d;
        ssl_session_cache   shared:SSL:10m;

        # 보안 헤더
        add_header Strict-Transport-Security "max-age=63072000" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "DENY" always;

        # 모든 경로를 LiteLLM으로 프록시 (RBAC는 LiteLLM이 담당)
        location / {
            proxy_pass http://litellm_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;

            # SSE (스트리밍) 지원 — Codex CLI에 필요
            proxy_buffering off;
            proxy_cache off;
            chunked_transfer_encoding on;

            # 타임아웃 — 장시간 LLM 응답 수용
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
        }
    }
}
NGINX
```

## 11.3 D1 대비 변경점

| 항목 | D1 | D2 |
|------|----|----|
| 포트 | 80(사용자) + 8443(관리자) | 80→443 리다이렉트 + 443(HTTPS) |
| 경로 차단 | `/ui`, `/key/generate`, `/spend/*` 등 차단 | 차단 없음 (RBAC는 LiteLLM이 담당) |
| IP 제한 | 8443에서 사설 IP 대역만 | 제거 (SSO 인증으로 대체) |
| TLS | 없음 (HTTP) | TLS 1.2/1.3 강제 |

---

# 12. Phase 4 — Docker Compose 구성

## 12.1 docker-compose.yml

```bash
cat > docker-compose.yml << 'YAML'
x-common: &common
  restart: unless-stopped

services:
  # ─── OpenBao ───
  openbao:
    <<: *common
    image: openbao/openbao:latest
    container_name: openbao
    cap_add:
      - IPC_LOCK
    environment:
      BAO_ADDR: "http://0.0.0.0:8200"
      SKIP_SETCAP: "true"
    volumes:
      - ./openbao/config:/openbao/config:ro
      - ./openbao/data:/openbao/data
      - ./openbao/logs:/openbao/logs
    command: server -config=/openbao/config/openbao.hcl
    networks:
      - llm-net
    healthcheck:
      test: ["CMD", "bao", "status", "-address=http://127.0.0.1:8200"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 5s

  # ─── PostgreSQL ───
  postgres:
    <<: *common
    image: postgres:16-alpine
    container_name: litellm-db
    environment:
      POSTGRES_DB: litellm
      POSTGRES_USER: litellm
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ./postgres:/var/lib/postgresql/data
    networks:
      - llm-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U litellm"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ─── LiteLLM Proxy ───
  litellm:
    <<: *common
    image: docker.litellm.ai/berriai/litellm-database:main-latest
    container_name: litellm-proxy
    depends_on:
      postgres:
        condition: service_healthy
      openbao:
        condition: service_started
    environment:
      DATABASE_URL: "postgresql://litellm:${POSTGRES_PASSWORD}@postgres:5432/litellm"
      LITELLM_MASTER_KEY: "${LITELLM_MASTER_KEY}"
      PROXY_BASE_URL: "${PROXY_BASE_URL}"

      # OpenBao (Vault 호환)
      HCP_VAULT_ADDR: "http://openbao:8200"
      HCP_VAULT_TOKEN: "${OPENBAO_ROOT_TOKEN}"
      HCP_VAULT_MOUNT_NAME: "secret"
      HCP_VAULT_PATH_PREFIX: "litellm"
      HCP_VAULT_REFRESH_INTERVAL: "3600"

      # ── OIDC SSO ──
      GENERIC_CLIENT_ID: "${GENERIC_CLIENT_ID}"
      GENERIC_CLIENT_SECRET: "${GENERIC_CLIENT_SECRET}"
      GENERIC_AUTHORIZATION_ENDPOINT: "${GENERIC_AUTHORIZATION_ENDPOINT}"
      GENERIC_TOKEN_ENDPOINT: "${GENERIC_TOKEN_ENDPOINT}"
      GENERIC_USERINFO_ENDPOINT: "${GENERIC_USERINFO_ENDPOINT}"
      GENERIC_USER_ID_JWT_FIELD: "${GENERIC_USER_ID_JWT_FIELD}"
      GENERIC_USER_EMAIL_JWT_FIELD: "${GENERIC_USER_EMAIL_JWT_FIELD}"
      GENERIC_USER_FIRST_NAME_JWT_FIELD: "${GENERIC_USER_FIRST_NAME_JWT_FIELD}"
      GENERIC_USER_LAST_NAME_JWT_FIELD: "${GENERIC_USER_LAST_NAME_JWT_FIELD}"
      GENERIC_USER_ROLE_JWT_FIELD: "${GENERIC_USER_ROLE_JWT_FIELD}"
      ALLOWED_USER_EMAIL_DOMAINS: "${ALLOWED_USER_EMAIL_DOMAINS}"
      DEFAULT_USER_ROLES_LITELLM_SSO: "${DEFAULT_USER_ROLES_LITELLM_SSO}"
    volumes:
      - ./litellm/config.yaml:/app/config.yaml
    command: --config /app/config.yaml --port 4000 --detailed_debug
    networks:
      - llm-net

  # ─── Nginx (TLS, 단일 진입점) ───
  nginx:
    <<: *common
    image: nginx:alpine
    container_name: llm-nginx
    depends_on:
      - litellm
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/certs:/etc/nginx/certs:ro
    networks:
      - llm-net

networks:
  llm-net:
    driver: bridge
YAML
```

## 12.2 D1 대비 변경점

- 노출 포트: `80, 8443` → `80, 443`
- LiteLLM 환경변수: SSO 관련 항목 추가
- Nginx 볼륨: TLS 인증서 마운트 추가

---

# 13. Phase 5 — OpenBao 초기화 및 사용자 OpenAI Key 저장

> D1 §3과 동일. 본 단계만 변경 없음.

## 13.1 기동 → 초기화 → Unseal

```bash
docker compose up -d openbao
sleep 3

docker exec openbao bao operator init \
  -key-shares=5 -key-threshold=3 \
  -format=json > openbao/init-keys.json
chmod 600 openbao/init-keys.json

for i in 0 1 2; do
  KEY=$(jq -r ".unseal_keys_b64[$i]" openbao/init-keys.json)
  docker exec openbao bao operator unseal "$KEY"
  sleep 1
done

docker exec openbao bao status

ROOT_TOKEN=$(jq -r '.root_token' openbao/init-keys.json)
sed -i "s/^OPENBAO_ROOT_TOKEN=.*/OPENBAO_ROOT_TOKEN=$ROOT_TOKEN/" .env
```

> ⚠️ `init-keys.json`은 오프라인 백업 후 서버에서 삭제할 것.

## 13.2 KV 시크릿 엔진 활성화

```bash
ROOT_TOKEN=$(jq -r '.root_token' openbao/init-keys.json)

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao secrets enable -path=secret -version=2 kv
```

## 13.3 사용자별 OpenAI Key 저장 (10명)

```bash
ROOT_TOKEN=$(jq -r '.root_token' openbao/init-keys.json)

for i in 01 02 03 04 05 06 07 08 09 10; do
  docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
    bao kv put "secret/litellm/USER${i}_OPENAI_KEY" \
    key="sk-proj-user${i}-real-openai-key"
done

# 검증
docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv get secret/litellm/USER01_OPENAI_KEY
```

> 실제 환경에서는 각 사용자의 실제 OpenAI API Key를 입력한다. 위 스크립트는 형식 예시.

---

# 14. Phase 6 — LiteLLM 설정 (모델 매핑 + SSO + TTL)

## 14.1 litellm/config.yaml 전체

```yaml
cat > litellm/config.yaml << 'YAML'
# ══════════════════════════════════════════════════════════
# LiteLLM Proxy v2 — SSO + 사용자별 OpenAI Key 매핑 + 24h TTL
# ══════════════════════════════════════════════════════════

# ─────────────────────────────────────
# model_list — 사용자별 전용 모델 항목 (D1과 동일)
# ─────────────────────────────────────
model_list:
  # User 01
  - model_name: user01-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER01_OPENAI_KEY"
  - model_name: user01-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER01_OPENAI_KEY"

  # User 02
  - model_name: user02-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER02_OPENAI_KEY"
  - model_name: user02-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER02_OPENAI_KEY"

  # User 03
  - model_name: user03-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER03_OPENAI_KEY"
  - model_name: user03-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER03_OPENAI_KEY"

  # User 04
  - model_name: user04-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER04_OPENAI_KEY"
  - model_name: user04-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER04_OPENAI_KEY"

  # User 05
  - model_name: user05-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER05_OPENAI_KEY"
  - model_name: user05-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER05_OPENAI_KEY"

  # User 06
  - model_name: user06-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER06_OPENAI_KEY"
  - model_name: user06-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER06_OPENAI_KEY"

  # User 07
  - model_name: user07-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER07_OPENAI_KEY"
  - model_name: user07-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER07_OPENAI_KEY"

  # User 08
  - model_name: user08-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER08_OPENAI_KEY"
  - model_name: user08-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER08_OPENAI_KEY"

  # User 09
  - model_name: user09-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER09_OPENAI_KEY"
  - model_name: user09-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER09_OPENAI_KEY"

  # User 10
  - model_name: user10-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER10_OPENAI_KEY"
  - model_name: user10-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER10_OPENAI_KEY"


# ─────────────────────────────────────
# General Settings
# ─────────────────────────────────────
general_settings:
  master_key: "os.environ/LITELLM_MASTER_KEY"
  database_url: "os.environ/DATABASE_URL"
  proxy_base_url: "os.environ/PROXY_BASE_URL"

  # OpenBao 연동 (D1과 동일)
  key_management_system: "hashicorp_vault"
  key_management_settings:
    store_virtual_keys: true
    prefix_for_stored_virtual_keys: "litellm/vkeys/"
    access_mode: "read_and_write"

  # 입출력 로그 저장 (D1과 동일)
  store_model_in_db: true
  store_prompts_in_spend_logs: true
  maximum_spend_logs_retention_period: "90d"
  maximum_spend_logs_retention_interval: "1d"

  # ── v2 신규: Default Key TTL 24h ──
  default_key_generate_params:
    duration: "24h"

  # ── v2 신규: Key 발급 정책 강제 (TTL 상한) ──
  key_generation_settings:
    require_team_id: false
    enforce_key_generate_params:
      duration:
        max: "24h"

  # ── v2 신규: SSO 그룹 → 역할 매핑 ──
  litellm_jwtauth:
    user_id_jwt_field: "email"
    user_email_jwt_field: "email"
    roles_jwt_field: "groups"
    role_mappings:
      llm-gateway-admins: "proxy_admin"
      llm-gateway-users: "internal_user"

  # ── v2 신규: UI 사용자 Key 발급 권한 허용 ──
  allow_user_auth: true
  ui_access_mode: "all_authenticated_users"


# ─────────────────────────────────────
# Router / LiteLLM Settings
# ─────────────────────────────────────
router_settings:
  num_retries: 2
  timeout: 120

litellm_settings:
  drop_params: true
  set_verbose: false
YAML
```

## 14.2 v2 신규 설정 항목 해설

| 설정 키 | 의미 | 효과 |
|--------|------|-----|
| `default_key_generate_params.duration: "24h"` | UI/API에서 Key 발급 시 기본 만료 시각 | 사용자가 명시하지 않으면 24h 후 만료 |
| `key_generation_settings.enforce_key_generate_params.duration.max: "24h"` | 사용자가 24h를 초과하는 만료 시각을 지정할 수 없음 | 정책 우회 방지 |
| `litellm_jwtauth.role_mappings` | SSO 그룹 → LiteLLM 내부 역할 매핑 | `llm-gateway-admins`는 proxy_admin, 그 외는 internal_user |
| `allow_user_auth: true` | 일반 사용자가 본인 Virtual Key를 UI에서 직접 발급 허용 | 사용자 셀프서비스 |
| `ui_access_mode: all_authenticated_users` | SSO 인증된 모든 사용자가 UI 진입 가능 (RBAC로 화면 분기) | 단일 진입점 모델 |

> ⚠️ **검증 필요**: `key_generation_settings.enforce_key_generate_params`, `ui_access_mode`, `litellm_jwtauth.role_mappings`의 정확한 키 이름은 LiteLLM 사용 버전에서 한 번 더 확인할 것. 미지원 시 LiteLLM UI의 Settings에서 런타임 변경으로 대체.

---

# 15. Phase 7 — 시스템 기동

## 15.1 전체 서비스 시작

```bash
cd ~/llm-gateway

# 모든 서비스 기동
docker compose up -d

# 로그 확인
docker compose logs -f litellm
```

기대 로그:
- `Connected to PostgreSQL`
- `Loaded model_list (20 models)`
- `Vault connection established`
- `SSO endpoints registered: /sso/key/generate, /sso/callback`

## 15.2 헬스체크

```bash
# HTTPS 진입점 헬스체크 (자체서명 인증서일 경우 -k)
curl -k https://localhost/health

# HTTP → HTTPS 리다이렉트 확인
curl -I http://localhost
# 기대: HTTP/1.1 301 Moved Permanently / Location: https://localhost/
```

## 15.3 SSO 엔드포인트 노출 확인

```bash
# SSO 로그인 페이지 (브라우저로 접속해야 IdP로 리다이렉트)
curl -k -I https://localhost/sso/key/generate

# 모델 목록 (Master Key로)
curl -k https://localhost/v1/models \
  -H "Authorization: Bearer $(grep LITELLM_MASTER_KEY .env | cut -d= -f2)" \
  | jq '.data[].id'
```

기대: `user01-gpt-4o` ~ `user10-o3-mini` 20개 모델 표시.

---

# 16. Phase 8 — 사용자 사전등록

## 16.1 매핑 표 확정 (관리자 작업)

§5.2의 매핑 표를 실제 사내 인원으로 채운다. 결과를 다음 형식의 CSV로 준비:

```
email,slot,name
alice@company.com,user01,홍길동
bob@company.com,user02,김철수
...
jack@company.com,user10,한소율
```

## 16.2 사전등록 스크립트

```bash
cat > register_users.sh << 'BASH'
#!/bin/bash
# ──────────────────────────────────────────────
# register_users.sh
# SSO 이메일 ↔ user01~user10 슬롯 사전등록
# ──────────────────────────────────────────────

set -e

LITELLM_URL="https://llm-gateway.company.com"
MASTER_KEY="$(grep LITELLM_MASTER_KEY .env | cut -d= -f2)"

# 사용자 매핑 (실제 사내 인원으로 교체)
declare -A USER_MAP=(
  ["alice@company.com"]="user01"
  ["bob@company.com"]="user02"
  ["carol@company.com"]="user03"
  ["dave@company.com"]="user04"
  ["eve@company.com"]="user05"
  ["frank@company.com"]="user06"
  ["grace@company.com"]="user07"
  ["henry@company.com"]="user08"
  ["ivy@company.com"]="user09"
  ["jack@company.com"]="user10"
)

# 관리자 매핑 (별도)
ADMIN_EMAILS=(
  "admin1@company.com"
  "admin2@company.com"
)

echo "═══════════════════════════════════════════"
echo " 일반 사용자 등록"
echo "═══════════════════════════════════════════"

for EMAIL in "${!USER_MAP[@]}"; do
  SLOT="${USER_MAP[$EMAIL]}"

  RESULT=$(curl -sk -X POST "${LITELLM_URL}/user/new" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"user_email\": \"${EMAIL}\",
      \"user_role\": \"internal_user\",
      \"models\": [\"${SLOT}-gpt-4o\", \"${SLOT}-o3-mini\"],
      \"max_budget\": 50.0,
      \"budget_duration\": \"30d\",
      \"metadata\": {\"slot\": \"${SLOT}\"}
    }")

  USER_ID=$(echo "$RESULT" | jq -r '.user_id // "ERROR"')
  echo "  ${EMAIL} → ${SLOT}  (user_id: ${USER_ID})"
done

echo ""
echo "═══════════════════════════════════════════"
echo " 관리자 등록"
echo "═══════════════════════════════════════════"

for EMAIL in "${ADMIN_EMAILS[@]}"; do
  RESULT=$(curl -sk -X POST "${LITELLM_URL}/user/new" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"user_email\": \"${EMAIL}\",
      \"user_role\": \"proxy_admin\"
    }")

  USER_ID=$(echo "$RESULT" | jq -r '.user_id // "ERROR"')
  echo "  ${EMAIL} → proxy_admin  (user_id: ${USER_ID})"
done

echo ""
echo "═══════════════════════════════════════════"
echo " 사전등록 완료"
echo "═══════════════════════════════════════════"
BASH

chmod +x register_users.sh
./register_users.sh
```

## 16.3 등록 검증

```bash
# 등록된 사용자 목록 조회
curl -sk "https://llm-gateway.company.com/user/list" \
  -H "Authorization: Bearer $(grep LITELLM_MASTER_KEY .env | cut -d= -f2)" \
  | jq '.users[] | {email: .user_email, role: .user_role, models: .models, slot: .metadata.slot}'
```

기대: 사용자 10명 + 관리자 N명, 각 사용자에 user01~user10 슬롯 모델이 매핑됨.

---

# 17. Phase 9 — 검증 시나리오

> 본 단계는 **시나리오 단위 통합 테스트**다. 각 항목이 통과해야 D2 구현이 완료된 것.

## 17.1 시나리오 1 — 일반 사용자 SSO 로그인

```
[테스트] alice@company.com (llm-gateway-users 그룹 멤버)

1. 브라우저에서 https://llm-gateway.company.com/ 접속
   → LiteLLM 기본 페이지 표시
2. "Sign in with SSO" 클릭
   → 사내 IdP 로그인 페이지로 리다이렉트
3. SSO 인증
   → LiteLLM /sso/callback으로 복귀
4. UI 진입 확인:
   ✓ "Virtual Keys" 탭 보임
   ✓ "Usage" 탭 보임
   ✗ "Logs" 탭 보이지 않음 (관리자 전용)
   ✗ "Internal Users" 탭 보이지 않음
   ✗ "Models" 탭 보이지 않음
5. "Virtual Keys" 탭에서:
   - 본인 Key가 자동 생성되어 있거나 "Create Key" 버튼이 보임
   - 발급된 Key의 "Models" 컬럼에 "user01-gpt-4o, user01-o3-mini"만 표시
   - "Expires" 컬럼이 24h 후 시각 표시
6. 발급된 Key 값을 복사 → 환경변수 OPENAI_API_KEY 에 설정
7. Codex CLI 호출:
   curl -k https://llm-gateway.company.com/v1/chat/completions \
     -H "Authorization: Bearer ${VKEY}" \
     -d '{"model": "user01-gpt-4o", "messages": [{"role":"user","content":"hi"}]}'
   ✓ 정상 응답
```

## 17.2 시나리오 2 — 모델 격리 검증

```
[테스트] alice (user01 슬롯)가 user02-gpt-4o 호출 시도

curl -k https://llm-gateway.company.com/v1/chat/completions \
  -H "Authorization: Bearer ${ALICE_VKEY}" \
  -d '{"model": "user02-gpt-4o", "messages": [{"role":"user","content":"hi"}]}'

✓ HTTP 401/403 반환
✓ 에러 메시지: "Authentication Error: API Key not allowed to access model"
```

## 17.3 시나리오 3 — 관리자 SSO 로그인

```
[테스트] admin1@company.com (llm-gateway-admins 그룹 멤버)

1. 브라우저에서 https://llm-gateway.company.com/ 접속 → SSO 로그인
2. UI 진입 확인:
   ✓ "Logs" 탭 보임
   ✓ "Internal Users" 탭 보임
   ✓ "Models" 탭 보임
   ✓ "Usage" 탭에 전 사용자 데이터 표시
3. "Logs" 탭에서:
   - 시나리오 1에서 alice가 보낸 요청이 표시됨
   - 행 클릭 시 messages(prompt)와 response 전문 열람 가능
4. "Internal Users" 탭에서:
   - 사전등록한 10명 + 관리자 모두 표시
   - alice 행 클릭 → models 목록 변경/Key 차단 가능
5. "Models" 탭에서:
   - user01-gpt-4o ~ user10-o3-mini 20개 모델 표시
   - 각 모델의 api_key 필드는 마스킹 또는 vault 참조 표시
```

## 17.4 시나리오 4 — 비허용 사용자 차단

```
[테스트] outsider@external.com (그룹 비멤버 또는 도메인 외)

1. 브라우저에서 SSO 로그인 시도
2. IdP 인증 통과
3. LiteLLM /sso/callback 도달
   ✓ 화면: "권한이 없습니다" 또는 401 응답
   ✓ 사용자가 PostgreSQL에 자동 생성되지 않거나, 생성되어도 internal_user_viewer 역할로 빈 UI 노출
```

## 17.5 시나리오 5 — Key 24h TTL

```
[테스트] alice가 발급받은 Key의 만료 동작

1. Key 발급 직후:
   curl -k https://llm-gateway.company.com/key/info \
     -H "Authorization: Bearer ${VKEY}" | jq '.info.expires'
   ✓ 24h 후 ISO 8601 시각

2. 만료 후 호출 (date 조작 또는 TTL=1m으로 임시 단축 후 테스트):
   curl -k https://llm-gateway.company.com/v1/chat/completions \
     -H "Authorization: Bearer ${VKEY}" \
     -d '...'
   ✓ HTTP 401: "API Key expired"

3. UI 재로그인 → "Regenerate" 클릭 → 새 Key 발급
   ✓ 새 Key로 호출 정상 동작
```

## 17.6 시나리오 6 — 권한 회수

```
[테스트] IdP에서 alice를 llm-gateway-users 그룹에서 제거

1. IdP 콘솔에서 그룹 제거
2. alice의 기존 Virtual Key로 호출:
   ✓ 24h 이내: 정상 동작 (유효 기간 남아있는 Key는 즉시 차단되지 않음)
   ✓ 관리자가 즉시 차단을 원하면 LiteLLM UI에서 alice의 Key를 block
3. alice가 SSO 재로그인 시도:
   ✓ 그룹 클레임 검증 실패 → UI 진입 거부
4. 24h 후 기존 Key는 자동 만료
```

## 17.7 시나리오 7 — Codex CLI End-to-End

```
[테스트] alice 사용자 PC에서 실제 Codex CLI 사용

1. ~/.codex/config.toml 생성:
   openai_base_url = "https://llm-gateway.company.com/v1"
   model = "user01-gpt-4o"
   approval_mode = "suggest"

2. 환경변수:
   export OPENAI_API_KEY="<alice의 Virtual Key>"

3. CLI 실행:
   codex exec "이 프로젝트에 README.md를 만들어줘"

   ✓ 정상 응답 스트리밍
   ✓ 관리자 UI Logs 탭에서 해당 요청 확인 가능
   ✓ alice UI Usage 탭에서 spend 증가 확인
```

---

# 18. 사용자 가이드 (배포용)

> 이 섹션은 사용자에게 그대로 배포할 수 있는 안내문이다.

## 18.1 LLM Access Gateway 사용 안내

### 사전 조건
- 사내 SSO 계정
- 관리자에게 LLM Gateway 사용 권한 신청 완료 (그룹 등록됨)

### Step 1 — UI 접속 및 SSO 로그인

1. 브라우저에서 `https://llm-gateway.company.com/` 접속
2. "Sign in with SSO" 클릭 → 사내 SSO 인증
3. UI 진입 후 "Virtual Keys" 탭 클릭

### Step 2 — Virtual Key 발급

1. "Create New Key" 또는 "Regenerate" 버튼 클릭
2. 발급된 Key 값을 복사 (`sk-vk-...` 형식)
3. **24시간 후 만료**되므로 매일 다시 발급 필요

### Step 3 — Codex CLI 설치 및 설정 (최초 1회)

```bash
# Codex CLI 설치
npm install -g @openai/codex

# 설정 파일
mkdir -p ~/.codex
cat > ~/.codex/config.toml << 'TOML'
openai_base_url = "https://llm-gateway.company.com/v1"
model = "userXX-gpt-4o"   # XX는 본인 슬롯 번호 (관리자에게 확인)
approval_mode = "suggest"
TOML
```

### Step 4 — 환경변수 설정 (매일)

```bash
# Virtual Key를 환경변수에 입력 (24h 마다 갱신)
export OPENAI_API_KEY="sk-vk-..."
```

`~/.bashrc`에 영구 등록할 수 있으나, **24시간 후 만료되면 갱신해야 한다**.

### Step 5 — Codex CLI 사용

```bash
codex                                              # 대화형
codex --model userXX-gpt-4o                        # 모델 명시
codex exec "README.md를 만들어줘"                  # 일회성
```

## 18.2 사용량 확인

UI의 "Usage" 탭에서 실시간 확인 가능. CLI에서 빠르게 확인하려면:

```bash
curl -sk "https://llm-gateway.company.com/key/info" \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  | jq '{spend: .info.spend, max_budget: .info.max_budget, expires: .info.expires}'
```

## 18.3 24h Key 갱신 자동화 (셸 함수 예시)

`.bashrc`에 추가하면 매일 UI 재방문 후 클립보드 Key를 환경변수에 한 번에 적용 가능:

```bash
# 클립보드에 복사한 새 Key를 OPENAI_API_KEY 환경변수에 설정
llm_refresh() {
  export OPENAI_API_KEY=$(xclip -selection clipboard -o)  # Linux
  # macOS: export OPENAI_API_KEY=$(pbpaste)
  echo "Key 갱신: ${OPENAI_API_KEY:0:12}..."
}
```

## 18.4 트러블슈팅

| 증상 | 원인 | 해결 |
|-----|------|-----|
| `API Key expired` | 24h 만료 | UI 재로그인 → Regenerate |
| `model not found` | 슬롯 번호 오류 | 관리자에게 본인 슬롯 확인 |
| `not allowed to access model` | 다른 사용자의 모델 호출 시도 | 본인 모델(userXX-*)만 사용 |
| 브라우저에서 403 | SSO 그룹 비멤버 | 관리자에게 권한 신청 |

---

# 19. 운영 가이드

## 19.1 신규 사용자 추가 (5단계)

```bash
# 1. IdP에서 사용자를 llm-gateway-users 그룹에 추가 (IdP 콘솔)

# 2. OpenBao에 사용자의 OpenAI Key 저장 (사용 가능한 슬롯에)
ROOT_TOKEN=$(jq -r '.root_token' openbao/init-keys.json)
docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER11_OPENAI_KEY \
  key="sk-proj-user11-openai-key"

# 3. litellm/config.yaml에 모델 항목 추가 후 재시작
# (UI Models 탭에서도 가능)

# 4. LiteLLM에 사용자 사전등록
curl -sk -X POST "https://llm-gateway.company.com/user/new" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "user_email": "newuser@company.com",
    "user_role": "internal_user",
    "models": ["user11-gpt-4o", "user11-o3-mini"],
    "max_budget": 50.0,
    "budget_duration": "30d",
    "metadata": {"slot": "user11"}
  }'

# 5. 사용자에게 https://llm-gateway.company.com URL 안내
```

## 19.2 권한 회수 (즉시 차단)

**일반 회수**: IdP에서 그룹 제거 → 24h 내 자동 차단.

**즉시 차단**: LiteLLM UI → Internal Users → 해당 사용자 → "Block" 또는 모든 Key 일괄 차단.

```bash
# API로도 가능
curl -sk -X POST "https://llm-gateway.company.com/user/block" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "<user_id>"}'
```

## 19.3 OpenAI Key 로테이션 (사용자에게 영향 없음)

```bash
ROOT_TOKEN=$(jq -r '.root_token' openbao/init-keys.json)

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER01_OPENAI_KEY \
  key="sk-proj-user01-NEW-key"

docker compose restart litellm
```

사용자의 Virtual Key는 변경 없음. UI 재로그인도 불필요.

## 19.4 매핑 변경 (예: alice를 user01 → user05로 이동)

LiteLLM UI → Internal Users → alice → Edit → models 필드를 `["user05-gpt-4o", "user05-o3-mini"]`로 변경 → Save.

(기존 user01 슬롯은 다른 신규 사용자에게 할당 가능)

## 19.5 OpenBao Unseal 자동화

```bash
cat > openbao/unseal.sh << 'BASH'
#!/bin/bash
KEYS_FILE="/secure/path/to/init-keys.json"
for i in 0 1 2; do
  KEY=$(jq -r ".unseal_keys_b64[$i]" "$KEYS_FILE")
  docker exec openbao bao operator unseal "$KEY"
done
echo "[$(date)] OpenBao unsealed"
BASH
chmod 700 openbao/unseal.sh
```

systemd unit으로 등록하여 시스템 부팅 시 자동 실행 권장.

## 19.6 일일 운영 체크리스트

- [ ] OpenBao Sealed 상태 확인 (`docker exec openbao bao status`)
- [ ] LiteLLM `/health` 정상 응답
- [ ] 전일 spend 합계 확인 (UI Usage 탭)
- [ ] 만료 임박 Key 사용자 알림 (UI에서 자동, 별도 작업 불필요)
- [ ] 비정상 사용 패턴 점검 (Logs 탭에서 토큰 사용량 급증 행 확인)

---

# 20. 보안 체크리스트

## 20.1 PoC 배포 전 필수 확인

| 점검 항목 | 상태 | 비고 |
|----------|------|------|
| IdP OIDC 클라이언트 시크릿이 `.env`에만 저장 | ☐ | Git 커밋 금지 |
| `.env` 파일 권한 `chmod 600` | ☐ | |
| `init-keys.json` 오프라인 백업 후 서버에서 삭제 | ☐ | 분실 시 복구 불가 |
| LiteLLM Master Key 강력한 랜덤 문자열 | ☐ | `openssl rand -hex 32` |
| PostgreSQL 비밀번호 변경 | ☐ | |
| Nginx TLS 인증서 적용 | ☐ | PoC: 자체서명, 운영: 사내 CA/Let's Encrypt |
| `ALLOWED_USER_EMAIL_DOMAINS` 설정 | ☐ | 외부 도메인 차단 |
| IdP 그룹 멤버십 정책 정의 | ☐ | 누가 추가/삭제 권한을 갖는가 |
| 관리자 그룹은 최소 인원으로 제한 | ☐ | 2~3명 권장 |
| `default_key_generate_params.duration: "24h"` 동작 검증 | ☐ | 시나리오 5 |
| 모델 격리 동작 검증 | ☐ | 시나리오 2 |
| `store_prompts_in_spend_logs: true` 동작 검증 | ☐ | UI Logs에 prompt/response 표시 |
| 방화벽에서 4000, 5432, 8200 포트 외부 차단 | ☐ | Docker 내부만 허용 |
| OpenBao 감사 로그 활성화 | ☐ | `bao audit enable file file_path=/openbao/logs/audit.log` |

## 20.2 SSO 관련 추가 확인

| 점검 항목 | 상태 | 비고 |
|----------|------|------|
| 그룹 비멤버 사용자가 UI 접근 차단되는지 | ☐ | 시나리오 4 |
| IdP에서 그룹 제거 시 다음 SSO에서 차단되는지 | ☐ | 시나리오 6 |
| Redirect URI가 IdP에 정확히 등록되어 있는지 | ☐ | TLS URL 일치 |
| `state` 파라미터로 CSRF 방어되는지 | ☐ | LiteLLM 기본 동작 확인 |
| Master Key가 SSO 우회로 사용 가능한지 (정상 동작이지만 운영자 외 노출 금지) | ☐ | UI에 Master Key 입력 화면이 있으므로 환경변수만 사용 |

## 20.3 데이터 보호

| 점검 항목 | 상태 | 비고 |
|----------|------|------|
| `LiteLLM_SpendLogs` 테이블에 평문 prompt 저장됨을 인지 | ☐ | DB 접근 권한 최소화 |
| 로그 보관 기간이 사내 정책에 부합 | ☐ | 기본 90d |
| PostgreSQL 데이터 디렉토리 권한 제한 | ☐ | 호스트 root만 접근 |
| 백업 시 `init-keys.json`, `.env`, `postgres/` 모두 암호화 | ☐ | |

---

# 21. 트러블슈팅

## 21.1 SSO 로그인 후 빈 화면 / 권한 없음

**원인 1**: 그룹 클레임이 id_token에 포함되지 않음.

**해결**:
```bash
# IdP에서 발급된 토큰을 디코딩하여 groups 클레임 확인
docker compose logs litellm | grep -i "jwt"
# id_token 구조 확인 필요
```

**원인 2**: `litellm_jwtauth.role_mappings`의 그룹 이름과 IdP 그룹 이름이 정확히 일치하지 않음.

**해결**: config.yaml과 IdP 콘솔의 그룹 이름 대조 (대소문자 정확).

**원인 3**: 사용자가 `/user/new`로 사전등록되지 않음.

**해결**:
```bash
curl -sk "https://llm-gateway.company.com/user/list" \
  -H "Authorization: Bearer ${MASTER_KEY}" | jq '.users[].user_email'
# 사용자 이메일이 없으면 §16.2 스크립트 재실행
```

## 21.2 SSO Redirect URI Mismatch

**증상**: IdP에서 `redirect_uri_mismatch` 에러.

**원인**: IdP에 등록된 Redirect URI와 LiteLLM이 생성한 URI 불일치.

**해결**:
1. IdP 콘솔의 Redirect URI 확인 (예: `https://llm-gateway.company.com/sso/callback`)
2. `.env`의 `PROXY_BASE_URL` 값이 정확히 일치하는지 확인 (trailing slash 포함 여부 통일)
3. HTTP/HTTPS 프로토콜 일치 확인

## 21.3 24h Key가 만료되지 않음

**원인**: `default_key_generate_params.duration` 설정이 적용되지 않음 (LiteLLM 버전 차이).

**해결**:
1. LiteLLM UI → Settings → Key Generation Settings에서 런타임 설정 확인
2. 사용자의 기존 Key 만료 시각 확인:
   ```bash
   curl -sk "https://llm-gateway.company.com/key/info" \
     -H "Authorization: Bearer ${VKEY}" | jq '.info.expires'
   ```
3. 만료 시각이 null이면 `duration` 미적용 → UI에서 직접 설정하거나 config.yaml 키 이름 확인

## 21.4 사용자가 다른 사용자의 모델로 호출 가능

**증상**: alice의 Key로 user02-gpt-4o가 호출됨.

**원인**: 사전등록 시 `models` 배열을 잘못 지정.

**해결**:
```bash
# 사용자 정보 확인
curl -sk "https://llm-gateway.company.com/user/info?user_id=<alice_id>" \
  -H "Authorization: Bearer ${MASTER_KEY}" | jq '.user_info.models'

# UI 또는 API로 modesl 수정
curl -sk -X POST "https://llm-gateway.company.com/user/update" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -d '{"user_id": "<alice_id>", "models": ["user01-gpt-4o", "user01-o3-mini"]}'
```

## 21.5 Codex CLI 스트리밍 끊김

**원인**: Nginx 타임아웃 또는 buffering.

**해결**: §11.2 nginx.conf의 `proxy_read_timeout`, `proxy_buffering off` 확인. 미설정 시 추가 후 `docker compose restart nginx`.

## 21.6 OpenBao Unseal 후에도 LiteLLM이 시크릿을 못 읽음

**해결**:
1. OpenBao 상태: `docker exec openbao bao status` → `Sealed: false` 확인
2. LiteLLM의 `HCP_VAULT_TOKEN` 환경변수 값이 현재 Root Token과 일치 확인
3. 토큰 회전 시 `.env` 갱신 후 `docker compose restart litellm`

---

# 22. D1 대비 변경 요약

| 영역 | D1 | D2 |
|-----|----|----|
| **인증** | Virtual Key 자체가 인증 | SSO(OIDC) + Virtual Key 이중 |
| **권한 부여** | 관리자가 curl로 발급 → 메신저로 전달 | IdP 그룹 등록 + LiteLLM 사전등록 → 사용자 셀프서비스 |
| **Nginx** | 80(사용자) + 8443(관리자, IP 제한) | 80→443 리다이렉트 + 443(HTTPS, 단일 진입점) |
| **TLS** | 없음 | TLS 1.2/1.3 강제 |
| **사용자 페이지** | 없음 (curl만) | LiteLLM UI Internal User 뷰 |
| **관리자 페이지** | LiteLLM UI (IP 제한) | LiteLLM UI (SSO 그룹 기반) |
| **Virtual Key 수명** | 무제한 | **24시간 자동 만료** |
| **권한 회수** | `/key/block` API 호출 | IdP 그룹 제거 (24h 내 자동) |
| **사용자별 OpenAI Key 분리** | ✓ | ✓ (변경 없음) |
| **모델 매핑 (user01~user10)** | ✓ | ✓ (변경 없음) |
| **로그 저장** | ✓ | ✓ (변경 없음) |
| **사용자 사전등록** | 불필요 | **필수** (`/user/new` API) |
| **`.env` 항목 수** | 4개 | 17개 (SSO 관련 13개 추가) |

---

# 23. 참고자료

| 항목 | URL |
|------|-----|
| D1 시스템 요구사항 | [D1-system-requirements.md](D1-system-requirements.md) |
| LiteLLM SSO 설정 | https://docs.litellm.ai/docs/proxy/ui#setup-sso-jwt-auth |
| LiteLLM Virtual Keys | https://docs.litellm.ai/docs/proxy/virtual_keys |
| LiteLLM Internal User Endpoints | https://docs.litellm.ai/docs/proxy/users |
| LiteLLM JWT Auth | https://docs.litellm.ai/docs/proxy/token_auth |
| LiteLLM Key Generation Settings | https://docs.litellm.ai/docs/proxy/key_generation |
| LiteLLM Hashicorp Vault 연동 | https://docs.litellm.ai/docs/secret_managers/hashicorp_vault |
| OpenBao 공식 문서 | https://openbao.org/docs/ |
| OIDC Authorization Code Flow | https://openid.net/specs/openid-connect-core-1_0.html |
| Codex CLI 설정 | https://developers.openai.com/codex/config-basic |

---

**문서 끝.** 본 문서로 D2 PoC 구현에 즉시 착수 가능. 검증 시나리오(§17) 7개를 모두 통과해야 PoC 완료로 본다.
