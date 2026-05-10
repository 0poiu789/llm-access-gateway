# D4 — 참조 아키텍처 갭 분석 및 개선 설계

> **목적**: 외부에서 흔히 제시되는 "Vault 기반 LLM 게이트웨이" 참조 아키텍처(이하 *사례*)와 본 PoC(OpenBao + LiteLLM OSS) 구현 사이의 갭을 단계별로 분석하고, 각 갭을 메우기 위한 작업 항목(WI)을 구현 가능한 수준까지 설계한다.
>
> 이 문서를 읽고 바로 코드 작업으로 진입할 수 있도록, 각 WI는 **변경 대상 파일·라인**, **신규 명령/HCL 정책 텍스트**, **검증 방법**, **완료 기준(DoD)** 을 포함한다.

---

## 0. 용어 정리

| 용어 | 정의 |
|------|------|
| **OpenBao** | HashiCorp Vault의 Linux Foundation 포크. CLI(`bao`), HTTP API, HCL policy, AppRole, KV v2 등 모든 핵심 개념이 Vault와 호환. 본 PoC가 사용하는 시크릿 저장소. |
| **사례** | 본 문서가 비교 대상으로 삼는 일반화된 참조 아키텍처(아래 §1.1). 외부 자료에서 "VAULT"로 표기됐으나 본 PoC 컨텍스트에서는 OpenBao로 매핑된다. |
| **API_KEY(C)** | OpenAI 콘솔에서 발급된 실제 OpenAI API Key. *Customer key* 또는 *Cloud key*. |
| **API_KEY(V)** | LiteLLM이 OpenBao에 접근할 때 사용하는 인증 토큰. *Vault access token*. 사례에서는 root 토큰이 아닌 제한 정책의 토큰. |
| **API_KEY(L)** | LiteLLM이 사용자에게 발급하는 Virtual Key (`sk-vk-…`). *LiteLLM virtual key*. |
| **SSOT** | Single source of truth. |
| **WI** | Work Item. 본 문서에서 정의하는 개선 작업 단위. |

---

## 1. 사례 아키텍처

### 1.1 6단계 흐름

```
① 관리자 → OpenAI 콘솔 로그인
② 관리자 → API_KEY(C) 발급
③ 관리자 → C를 OpenBao에 저장
④ 관리자 → LiteLLM 전용 OpenBao 토큰(V) 발급 (제한 정책)
⑤ LiteLLM → V로 OpenBao에서 C를 직접 조회
⑥ LiteLLM → (V + 사용자 IP)로 사용자별 API_KEY(L) 생성
⑦ 관리자 → L을 사용자에게 배포
```

(편의상 7단계로 분해. 사용자 메시지의 6단계와 동일.)

### 1.2 사례의 핵심 보안 가정

- **A1.** OpenBao만이 OpenAI Key의 SSOT. 평문 파일에 키가 존재하지 않음.
- **A2.** LiteLLM은 root 권한이 아닌 **read-only AppRole**(또는 제한 토큰)으로 OpenBao에 접근. 정책으로 path를 한정.
- **A3.** Virtual Key(L)는 사용자 IP/CIDR에 바인딩되어 도난 시 재사용이 차단됨.
- **A4.** 모든 시크릿 read/write가 OpenBao audit log에 기록됨.

본 분석은 이 4가지 가정 각각을 현재 구현에 비추어 평가한다.

---

## 2. 단계별 갭 분석 (사례 vs 현재 PoC)

### 2.1 요약 매트릭스

| 단계 | 사례 | 현재 PoC | 상태 | 핵심 갭 원인 |
|------|------|----------|------|-------------|
| ① OpenAI Key(C) 발급 | 관리자 콘솔 작업 | 동일 | ✅ 동일 | — |
| ② C → OpenBao 저장 | UI/CLI | `set-openai-key.sh` / `bao kv put` / OpenBao Web UI | ✅ 동일 | — |
| ③ LiteLLM용 토큰(V) 발급 | AppRole + 제한 정책 | **root_token 단독 사용** | ❌ 불가 | 정책/AppRole 미구성 |
| ④ LiteLLM이 C를 직접 조회 | Vault 직접 연동 | OpenBao → `.env` → 컨테이너 OS env (미러링) | ❌ 불가 | **LiteLLM OSS 한계 — Vault 직접 연동은 Enterprise 전용** |
| ⑤ L 발급 시 IP 바인딩 | `allowed_ips` 적용 | 모델 화이트리스트 + 24h TTL만 | △ 부분 | 미구현 (LiteLLM 자체는 지원) |
| ⑥ L 사용자 배포 | 안전 채널 | `scripts/sample-keys.txt` | ✅ 동일 | — |
| (감사) Audit log | 활성화 | 미활성 | ❌ 부재 | 별도 작업 필요 |
| (관리) OpenBao Web UI 접근 | 관리자 IP에서 가능 | 8200 호스트 미노출 | △ 부분 | 보안 절충 |

### 2.2 단계별 상세

#### ① OpenAI Key(C) 발급 — ✅ 동일

사례와 동일. 관리자가 OpenAI 콘솔에서 발급. 본 PoC의 운영 가이드는 [admin-guide.md §4.2](../guides/admin-guide.md)에서 IP 화이트리스트/한도 설정을 권장한다.

**SSO 도입과 무관** — 항상 사람(관리자) 작업.

---

#### ② C → OpenBao 저장 — ✅ 동일

사례와 동일. 현재 PoC 경로:

| 방법 | 명령 |
|------|-----|
| 헬퍼 스크립트 | `./scripts/set-openai-key.sh user01 sk-proj-…` |
| stdin (셸 히스토리 회피) | `./scripts/set-openai-key.sh user01 -` |
| `bao` CLI 직접 | `docker exec -e BAO_TOKEN=$ROOT_TOKEN openbao bao kv put secret/litellm/USER01_OPENAI_KEY key=…` |
| OpenBao Web UI | (현재 8200 미노출 — WI-5 참조) |

**남은 작은 갭**:
- `set-openai-key.sh`가 **root_token**을 사용한다는 점이 ③의 갭과 직결. 적재 자체는 root여야 자연스럽지만, **읽기**는 제한 정책으로 분리 가능.
- 일괄 적재(10명 한 번에) 도구 없음. 필요 시 셸 루프로 충분.

**SSO 도입과 무관** — 시크릿 적재는 항상 관리자.

---

#### ③ LiteLLM용 토큰(V) 발급 — ❌ 불가 (현재 미구현)

**사례**: LiteLLM은 `secret/litellm/USER*_OPENAI_KEY` 경로의 **read-only** 정책을 가진 AppRole 토큰으로만 OpenBao에 접근. root 토큰은 부트스트랩 후 오프라인 보관.

**현재**:
- [scripts/02-load-secrets.sh:37](../../scripts/02-load-secrets.sh#L37) — `ROOT_TOKEN`을 `init-keys.json`에서 추출하여 모든 KV 호출에 사용.
- [scripts/01-init-openbao.sh:67-71](../../scripts/01-init-openbao.sh#L67-L71) — `OPENBAO_ROOT_TOKEN`이 `.env`에 평문 기록.
- LiteLLM 컨테이너는 OpenBao에 직접 접근하지 않으므로 V가 없어도 동작은 함. 하지만 *관리 도구(02-load-secrets, set-openai-key)* 가 root로 동작하는 것은 사례 가정 A2를 위반.

**갭의 영향**:
- root_token이 노출되면 OpenBao의 모든 시크릿이 노출 + 정책/엔진 변경 가능. 폭발 반경이 크다.
- 자동화 스크립트(예: 야간 키 회전 cron)에 root를 박아두는 것은 안티패턴.

**해결**: **WI-1 — Policy + AppRole 분리** 참조.

**SSO 도입과 무관** — OpenBao 자체의 인증 정책 문제.

---

#### ④ LiteLLM이 C를 직접 조회 — ❌ 불가 (LiteLLM OSS 한계)

**사례**: LiteLLM이 부팅/런타임에 V를 사용해 OpenBao API로 C를 가져온다. 평문 파일 단계 없음.

**현재**:
- [litellm/config.yaml:11](../../litellm/config.yaml#L11) — `api_key: "os.environ/USER01_OPENAI_KEY"` 표기만 사용. LiteLLM **OSS는 OS 환경변수만** 해석한다.
- [scripts/02-load-secrets.sh](../../scripts/02-load-secrets.sh) — OpenBao → `.env` 미러링이 불가피. `.env`는 docker-compose `env_file`로 컨테이너에 주입.
- 결과: 평문 키가 **OpenBao + `.env`(chmod 600) + 컨테이너 OS env** 3곳에 존재. 호스트 root / docker 그룹 사용자 / 호스트 침해 시 모두 노출.

**갭의 원인**: LiteLLM의 Vault/OpenBao 직접 연동(`vault://` 또는 동등 표기)은 **Enterprise 라이선스 전용**. OSS 코드 베이스에는 해당 resolver가 없다.

**갭의 영향**:
- `.env` 평문 단계가 sources of compromise로 추가됨.
- Key 회전 시 OpenBao만 갱신해도 LiteLLM이 새 값을 반영하려면 `.env` 재기록 + 컨테이너 재기동 필요. `docker compose restart`로는 env가 재로딩되지 않아 `up -d --force-recreate` 또는 `./start.sh`가 강제됨.

**해결 옵션**: **WI-2 — vault-agent sidecar** (사례에 가장 가까운 우회) 또는 LiteLLM Enterprise 전환(라이선스 비용).

**SSO 도입과 무관** — 라이선스/통합 문제.

---

#### ⑤ L 발급 시 IP 바인딩 — △ 부분 (LiteLLM OSS 한계로 silent-drop)

**사례**: `/key/generate` 호출 시 `allowed_ips` 필드에 사용자의 IP/CIDR 리스트를 넣어 도난 키 재사용을 차단.

**현재 PoC**:
- 클라이언트 wiring(`scripts/03-register-users.sh`)은 4-field `users.conf`의 `ALLOWED_IPS`를 `/key/generate` 페이로드에 그대로 주입한다.
- 그러나 **LiteLLM OSS 1.82.x의 `LiteLLM_VerificationToken` 테이블에는 `allowed_ips` 컬럼이 없고**, `/key/generate`는 이 파라미터를 200으로 받지만 silent-drop한다 (검증: `tests/07-test-ip-binding.sh`).
- 즉 클라이언트 측은 *준비*되어 있으나, OSS 서버가 영속화/시행하지 않는다.

**갭의 영향**: Virtual Key가 사내 메신저/이메일 등에서 유출되면 24h TTL 만료까지 **어느 IP에서든 재사용 가능**.

**해결 옵션**:
- (a) LiteLLM Enterprise — per-key `allowed_ips`가 정식 지원될 가능성 (라이선스 필요)
- (b) LiteLLM 업스트림 마이그레이션 추가 후 활성화 — 현재 wiring이 자동으로 효과 발휘
- (c) **단기 우회**: nginx에서 사용자별 경로/Bearer-prefix → IP 매핑 검사. 복잡하므로 비권장
- (d) **차선**: LiteLLM OSS의 글로벌 `general_settings.allowed_ip_addresses` (게이트웨이 진입 자체를 IP로 차단). 사용자별이 아니라 게이트웨이 전체 단위.

**SSO 도입과 무관** — 백엔드 영속화 한계.

---

#### ⑥ L 사용자 배포 — ✅ 동일 (단 자동화 부재)

사례와 동일하게 안전 채널 전달. 현재 [scripts/sample-keys.txt](../../scripts/sample-keys.txt)에 라인 단위 출력.

**남은 갭**:
- 자동 배포 채널 미연동 (사내 메신저 API, 이메일 자동 발송 등). 운영 시 추가 가능하지만 본 문서 비범위.
- 24h 만료 시 매일 일괄 재발급 → 관리자 부담. **SSO 도입 시 사용자 셀프서비스로 이전 가능** (WI-6).

---

#### (추가) OpenBao Audit Log — ❌ 부재

**사례 가정 A4**. 현재 [docker-compose.yml](../../docker-compose.yml)는 `./openbao/logs:/openbao/logs`만 마운트하고 audit device를 활성화하지 않는다. `bao audit list`는 빈 결과.

**갭의 영향**: 시크릿 read/write 추적 불가. 사고 발생 시 누가 어떤 키를 언제 읽었는지 입증 어려움.

**해결**: **WI-4 — OpenBao Audit Log 활성화**.

**SSO 도입과 무관**.

---

#### (추가) OpenBao Web UI — △ 부분

**현재**: docker-compose에 8200 포트가 호스트로 노출되지 않음 (보안 측면 권장 상태). 관리자가 시크릿을 GUI로 직접 보려면 `docker exec` 또는 SSH 포트포워딩이 필요.

**해결 옵션**: **WI-5 — OpenBao Web UI 관리자 접근**.

**SSO 도입과 무관**.

---

## 3. SSO 도입 시 변화 매트릭스

`.env`의 `GENERIC_*` 항목과 [docker-compose.sso.yml](../../docker-compose.sso.yml)은 이미 SSO 인프라를 갖추고 있다. 활성화 시 어떤 갭이 해소되는지를 분리한다.

| 항목 | SSO 비활성 (현재) | SSO 활성 후 |
|------|-----------------|------------|
| 사용자 UI 진입 | ❌ Internal User password 로그인 500 버그로 차단 | ✅ IdP 로그인으로 즉시 해소 |
| 사용자 셀프서비스 키 발급/재발급 | ❌ `./start.sh` 일괄 재발급 → 관리자 배포 | ✅ 사용자가 본인 페이지에서 직접 |
| 24h 만료 운영 부담 | 관리자 매일 작업 | 사용자 자율 |
| `sample-keys.txt` 배포 | 필요 | **불필요해짐** (관리자 전용 모니터링 용도로만) |
| 사용자 식별 신뢰성 | `users.conf`에 사람-슬롯 매핑 (관리자 작성 의존) | IdP의 `email`/`sub` claim 사용 (인증 시 검증) |
| 그룹/팀 기반 RBAC | 없음 | IdP `groups` claim → LiteLLM `user_role`로 매핑 (`DEFAULT_USER_ROLES_LITELLM_SSO`) |
| **③ AppRole/정책 분리** | ❌ | ❌ (별개 — WI-1) |
| **④ LiteLLM↔OpenBao 직접 연동** | ❌ | ❌ (별개 — WI-2 / Enterprise) |
| **⑤ IP 바인딩** | △ | △ (별개 — WI-3) |
| **Audit log** | ❌ | ❌ (별개 — WI-4) |

> **요점**: SSO는 **사용자 셀프서비스 / UI 접근 경로** 갭만 해소한다. 시크릿 보관/유통의 보안 갭(③④⑤)은 SSO와 직교하며, 별도 WI로 다뤄야 한다.

---

## 4. 개선 작업 항목 (Work Items)

각 WI는 다음 형식을 따른다:
- **목표**: 해결하려는 사례 단계 / 가정
- **변경 범위**: 영향 받는 파일·서비스
- **구현 단계**: 순서대로 적용할 변경
- **검증**: 변경이 제대로 적용됐는지 확인하는 방법
- **DoD (Definition of Done)**: 완료 판정 기준
- **위험/주의사항**

### 4.1 WI-1 · OpenBao Policy + AppRole 분리

**목표**: 사례 ③ + 가정 A2. LiteLLM 부속 도구가 root_token이 아닌 read-only AppRole 토큰으로 OpenBao에 접근하도록 한다. root_token은 부트스트랩 시점에만 사용하고 이후는 오프라인 보관.

**변경 범위**:
- `scripts/01-init-openbao.sh` — Phase 3 단계에서 policy + AppRole 생성 단계 추가
- `scripts/02-load-secrets.sh` — root 대신 AppRole로 인증
- `scripts/set-openai-key.sh` — *쓰기* 권한이 필요하므로 별도 정책(쓰기 가능) 또는 root 사용. 두 가지 옵션 중 택일 (아래).
- `.env` — `OPENBAO_LITELLM_ROLE_ID`, `OPENBAO_LITELLM_SECRET_ID` 추가, `OPENBAO_ROOT_TOKEN`은 단계적으로 제거
- `litellm/config.yaml` — 미변경 (LiteLLM은 OpenBao에 직접 접근 안 함, ④ 한계)

**구현 단계**:

1. `01-init-openbao.sh`에 다음 신규 단계 추가 (멱등):

   ```bash
   # 1) read-only policy 작성
   docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao bao policy write \
     -address=http://127.0.0.1:8200 litellm-readonly - <<HCL
   path "secret/data/litellm/*" {
     capabilities = ["read"]
   }
   HCL

   # 2) AppRole auth method 활성화
   docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao bao auth list \
     -address=http://127.0.0.1:8200 2>/dev/null | grep -q "^approle/" \
     || docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao bao auth enable \
        -address=http://127.0.0.1:8200 approle

   # 3) role 생성/갱신
   docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao bao write \
     -address=http://127.0.0.1:8200 \
     auth/approle/role/litellm \
     token_policies="litellm-readonly" \
     token_ttl=1h \
     token_max_ttl=24h \
     secret_id_ttl=0   # secret_id는 무한 (회전 시 재발급)

   # 4) role-id / secret-id 추출 → .env
   ROLE_ID=$(docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao bao read \
     -address=http://127.0.0.1:8200 -format=json \
     auth/approle/role/litellm/role-id \
     | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['role_id'])")
   SECRET_ID=$(docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao bao write \
     -address=http://127.0.0.1:8200 -format=json -f \
     auth/approle/role/litellm/secret-id \
     | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['secret_id'])")

   # 5) .env 갱신 (멱등)
   ```

2. `02-load-secrets.sh`에 AppRole 로그인 함수 추가:

   ```bash
   approle_login() {
     local role_id="$1" secret_id="$2"
     docker exec -e BAO_ADDR="http://127.0.0.1:8200" openbao \
       bao write -format=json auth/approle/login \
       role_id="$role_id" secret_id="$secret_id" \
       | python3 -c "import sys,json;print(json.load(sys.stdin)['auth']['client_token'])"
   }
   BAO_TOKEN=$(approle_login "$ROLE_ID" "$SECRET_ID")
   ```

3. `set-openai-key.sh` 옵션 결정:

   - **옵션 A (권장)**: 쓰기 전용 별도 정책 `litellm-writer` 추가하고 두 번째 AppRole 발급. 헬퍼는 이 토큰 사용. root는 부트스트랩 외 사용 안 함.
   - **옵션 B**: 적재 시점에만 root 사용 (헬퍼는 `init-keys.json` 직접 읽음). 일상 운영(02-load-secrets) 만 AppRole로 분리. 변경량 최소.

   본 PoC 권장: **옵션 B로 시작 → 운영 단계에서 옵션 A로 승격**.

4. `OPENBAO_ROOT_TOKEN` 사용 제거 후 `.env`에서 삭제. `init-keys.json` 권한 강화 가이드(이미 §3.3 docs/operations).

**검증**:

```bash
# AppRole 토큰으로 read는 성공해야 함
TOKEN=$(approle login)
docker exec -e BAO_TOKEN="$TOKEN" openbao bao kv get secret/litellm/USER01_OPENAI_KEY  # 200

# AppRole 토큰으로 write는 거부되어야 함 (옵션 A의 reader 토큰)
docker exec -e BAO_TOKEN="$TOKEN" openbao bao kv put secret/litellm/USER01_OPENAI_KEY key=x  # 403

# 기존 통합 테스트 6/6 그대로 통과
./tests/test-all.sh
```

**DoD**:
- [ ] `bao auth list`에 `approle/` 존재
- [ ] `bao policy list`에 `litellm-readonly` 존재
- [ ] `02-load-secrets.sh`가 `OPENBAO_ROOT_TOKEN` 환경변수를 더 이상 참조하지 않음
- [ ] `.env`에서 `OPENBAO_ROOT_TOKEN` 라인 제거 또는 비활성 표시
- [ ] 통합 테스트 6/6 통과

**위험**:
- `secret_id_ttl=0`은 무한 유효 — 회전 정책 별도 수립 필요. 운영 시 90d로 단축 권장.
- AppRole secret-id가 `.env`에 평문 저장 — 회전 빈도가 짧으면 위험 감소. 향후 [WI-2 vault-agent]가 이 단계도 흡수 가능.

---

### 4.2 WI-2 · vault-agent sidecar 도입 (사례 ④ 보강)

**목표**: 사례 ④. `.env`의 `USER01..10_OPENAI_KEY` 평문 캐시 단계를 제거. LiteLLM 컨테이너는 vault-agent가 OpenBao에서 직접 가져와 렌더링한 파일만 읽도록 한다.

**옵션 비교**:

| 옵션 | 장점 | 단점 | 권장 |
|------|------|------|------|
| **A. vault-agent sidecar** | OpenBao/Vault 표준 패턴, 키 변경 자동 감지, command 훅으로 컨테이너 재기동 | 컨테이너 1개 추가, AppRole 선행 필요(WI-1) | ★ 권장 |
| B. 자작 polling 스크립트 | 의존성 없음 | 재발명, 신뢰성 검증 필요 | 비권장 |
| C. LiteLLM Enterprise | `vault://` 직접 연동, 중간 단계 제거 | 라이선스 비용 | 별도 의사결정 |

**변경 범위**:
- `docker-compose.yml` — vault-agent 서비스 추가, LiteLLM의 `env_file` 변경
- `vault-agent/config.hcl` (신규) — auto-auth + template 설정
- `vault-agent/templates/litellm.env.tpl` (신규) — 키 매핑 템플릿
- `scripts/02-load-secrets.sh` — 동기화 책임 vault-agent로 이전, 스크립트 삭제 또는 첫 번째 부팅 시 placeholder 생성만 담당

**구현 단계**:

1. WI-1 완료 (AppRole role-id/secret-id 필요).

2. `vault-agent/config.hcl`:

   ```hcl
   pid_file = "/tmp/vault-agent.pid"

   auto_auth {
     method "approle" {
       config = {
         role_id_file_path = "/etc/vault-agent/role_id"
         secret_id_file_path = "/etc/vault-agent/secret_id"
         remove_secret_id_file_after_reading = false
       }
     }
     sink "file" {
       config = {
         path = "/tmp/vault-token"
       }
     }
   }

   vault {
     address = "http://openbao:8200"
   }

   template {
     source = "/etc/vault-agent/litellm.env.tpl"
     destination = "/run/secrets/litellm.env"
     perms = "0600"
     command = "sh -c 'docker compose -f /workspace/docker-compose.yml up -d --force-recreate litellm'"
     # 또는 사이드카에 docker.sock 마운트 필요. 대안: 시그널 사용 — 후술
   }
   ```

3. `vault-agent/templates/litellm.env.tpl`:

   ```
   {{- range $i := loop 1 11 -}}
   {{- $slot := printf "USER%02d_OPENAI_KEY" $i -}}
   {{- with secret (printf "secret/data/litellm/%s" $slot) -}}
   {{ $slot }}={{ .Data.data.key }}
   {{ end -}}
   {{- end -}}
   ```

   (range loop 문법은 vault-agent의 [consul-template]와 동일. 직접 풀어 쓰는 형태도 OK.)

4. `docker-compose.yml`에 추가:

   ```yaml
   vault-agent:
     image: openbao/openbao:latest
     command: agent -config=/etc/vault-agent/config.hcl
     depends_on:
       openbao:
         condition: service_healthy
     volumes:
       - ./vault-agent:/etc/vault-agent:ro
       - vault-agent-secrets:/run/secrets
     networks:
       - llm-net

   volumes:
     vault-agent-secrets:
   ```

   LiteLLM 서비스 변경:
   ```yaml
   litellm:
     env_file:
       - .env
       - /run/secrets/litellm.env  # vault-agent가 채움
     volumes:
       - vault-agent-secrets:/run/secrets:ro
     depends_on:
       vault-agent:
         condition: service_started
   ```

5. **재기동 트리거 처리**: vault-agent가 LiteLLM 컨테이너를 재기동하려면 docker.sock 권한이 필요. 보안상 회피하는 두 가지 방법:
   - **방법 1**: vault-agent가 시그널만 던지고 LiteLLM이 SIGHUP 처리 (LiteLLM OSS는 미지원 → 직접 패치 필요).
   - **방법 2** (권장): vault-agent의 `command`에서 빈 명령(`true`) 실행 + 별도 watchdog 스크립트가 `/run/secrets/litellm.env` 의 mtime 변화 감지 시 `docker compose restart litellm` 수행. watchdog은 호스트 cron 또는 단순 sidecar.

   본 WI에서는 **방법 2**를 채택 — `scripts/watch-secrets.sh` 신설.

6. `scripts/02-load-secrets.sh`는 **부트스트랩 placeholder만** 담당하도록 축소 (실제 미러링은 vault-agent로 이전).

**검증**:

```bash
# 1. vault-agent가 파일을 렌더링했는지
docker exec litellm cat /run/secrets/litellm.env  # 10개 라인 확인

# 2. .env에는 USER0n_OPENAI_KEY가 없어야 함 (제거됨)
grep "USER0[1-9]_OPENAI_KEY" .env  # no match

# 3. 키 변경 → 자동 반영
./scripts/set-openai-key.sh user01 sk-proj-NEWKEY
sleep 5
docker exec litellm grep USER01_OPENAI_KEY /run/secrets/litellm.env
# → 새 값으로 갱신되어 있어야 함
# → watchdog이 LiteLLM을 재기동했는지: docker compose ps (RESTARTED 시각 확인)

# 4. 통합 테스트 6/6 통과
./tests/test-all.sh
```

**DoD**:
- [ ] `.env`에서 `USER01..10_OPENAI_KEY` 라인 완전 제거
- [ ] `set-openai-key.sh` 후 5초 이내 LiteLLM이 새 키로 동작
- [ ] vault-agent 컨테이너 재기동 시 토큰 자동 재발급 (auto-auth)
- [ ] 통합 테스트 6/6 통과

**위험**:
- vault-agent + watchdog 조합은 사례 ④의 "직접 조회"보다 한 단계 우회. 평문 캐시는 `/run/secrets/litellm.env`(tmpfs 권장)로 이동했으나 여전히 존재. **완전 제거는 LiteLLM Enterprise만 가능**.
- `command` 훅을 docker.sock 없이 우회하므로 키 변경 ↔ 적용 사이 5~10초 지연.

---

### 4.3 WI-3 · Virtual Key IP 바인딩 (사례 ⑤)

**목표**: 사례 ⑤ + 가정 A3. `/key/generate` 호출 시 사용자 IP/CIDR을 묶어 도난 키 재사용을 차단.

**변경 범위**:
- `config/users.conf.example` — `ALLOWED_IPS` 필드 추가 (4-field로 확장)
- `scripts/03-register-users.sh` — `/key/generate` 페이로드에 `allowed_ips` 주입
- `tests/04-test-isolation.sh` — IP 바인딩 검증 케이스 추가
- 운영 가이드 — 사용자 IP 수집 절차

**구현 단계**:

1. `config/users.conf.example`을 4-field로 확장 (3-field 후방 호환):

   ```bash
   # SLOT|EMAIL|NAME[|ALLOWED_IPS]
   USERS=(
     "user01|alice@local|홍길동|10.0.1.5,10.0.1.6"
     "user02|bob@local|김철수|10.0.1.0/24"
     "user03|carol@local|이영희"          # IP 미지정 — 제한 없음 (현재 동작)
   )
   ```

2. `03-register-users.sh` 파싱 변경:

   ```bash
   IFS='|' read -r SLOT EMAIL NAME ALLOWED_IPS <<< "$entry"
   ALLOWED_IPS="${ALLOWED_IPS:-}"

   # /key/generate 페이로드에 조건부 추가
   ALLOWED_IPS_JSON=""
   if [[ -n "$ALLOWED_IPS" ]]; then
     ALLOWED_IPS_JSON=$(python3 -c "
   import json
   ips = '''$ALLOWED_IPS'''.split(',')
   print(json.dumps([ip.strip() for ip in ips if ip.strip()]))
   ")
   fi

   # /key/generate body 빌드 시 ALLOWED_IPS_JSON이 있으면 'allowed_ips' 키 추가
   ```

3. 통합 테스트에 케이스 추가 (`tests/04-test-isolation.sh`):

   - alice의 키를 alice의 IP에서 사용 → 통과
   - alice의 키를 다른 IP에서 사용 → 401 또는 403
   - LiteLLM이 source IP를 어떻게 인식하는지(직접 vs `X-Forwarded-For` 헤더) 미리 검증 필요. nginx에서 forward 설정 추가가 필요할 수 있음.

4. nginx 설정 검토:

   ```nginx
   proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
   proxy_set_header X-Real-IP $remote_addr;
   ```
   LiteLLM이 `X-Forwarded-For`의 마지막 IP를 source로 인식하는지 확인 (LiteLLM 설정에 `trust_x_forwarded_for: true` 등 옵션 점검).

**검증**:

```bash
# 1. alice 키 발급 시 allowed_ips 확인
curl -sk -H "Authorization: Bearer $MASTER" "$URL/key/info?key=$ALICE_KEY" | jq .info.allowed_ips
# → ["10.0.1.5", "10.0.1.6"]

# 2. 다른 IP에서 호출 차단
docker run --rm --network host curlimages/curl \
  --interface 192.168.99.1 -sk "$URL/v1/models" -H "Authorization: Bearer $ALICE_KEY"
# → 401 또는 403
```

**DoD**:
- [ ] users.conf에 ALLOWED_IPS 필드가 옵션으로 인식됨
- [ ] `/key/info` 응답의 `allowed_ips` 가 users.conf와 일치
- [ ] 다른 IP에서 키 사용 시 거부
- [ ] 기존 사용자(IP 미지정)는 동작 변화 없음

**위험**:
- 사용자 IP가 동적이면 운영 부담 증가. 사내 네트워크 CIDR을 일률 적용하는 절충안 권장.
- VPN/사내 프록시 통과 시 X-Forwarded-For 신뢰 체인 검증 필수 (스푸핑 방지).

---

### 4.4 WI-4 · OpenBao Audit Log 활성화 (가정 A4)

**목표**: 모든 시크릿 read/write를 audit log에 기록.

**변경 범위**:
- `scripts/01-init-openbao.sh` — KV 활성화 후 audit device 활성화 단계 추가
- `openbao/logs/` — audit.log 보존 디렉토리 (이미 마운트됨)
- 운영 가이드 — 로테이션/보존 정책

**구현 단계**:

1. `01-init-openbao.sh` 끝에 추가:

   ```bash
   if ! docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
        bao audit list -address="$BAO_ADDR_INTERNAL" 2>/dev/null | grep -q "file/"; then
     log "Enabling file audit device..."
     docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
       bao audit enable -address="$BAO_ADDR_INTERNAL" \
       -path=file file file_path=/openbao/logs/audit.log log_raw=false hmac_accessor=true
     log "✓ Audit device enabled at /openbao/logs/audit.log"
   else
     log "Audit device already enabled"
   fi
   ```

2. `openbao/logs/audit.log` 권한: OpenBao 컨테이너 uid가 쓸 수 있어야 함. 본 PoC에서 `chmod 777 openbao/logs`를 이미 적용 (호스트 perms 회피).

3. 로그 로테이션:
   - PoC: 단일 파일 누적. 운영 시 `logrotate` 또는 컨테이너 내 `bao audit disable file` 후 `enable`로 새 파일 시작.
   - 보존 기간: 90d 권장 (PostgreSQL spend log와 동일).

**검증**:

```bash
docker exec -e BAO_TOKEN=$ROOT_TOKEN openbao bao audit list  # file/ 표시
docker exec -e BAO_TOKEN=$ROOT_TOKEN openbao bao kv get secret/litellm/USER01_OPENAI_KEY  # 임의 read
tail -5 openbao/logs/audit.log | python3 -m json.tool  # 마지막 access가 JSON으로 기록
```

**DoD**:
- [ ] `bao audit list`에 `file/` 항목
- [ ] 임의 read/write가 audit.log에 1줄씩 추가됨
- [ ] HMAC된 토큰 accessor만 기록 (raw 토큰 미기록)

**위험**:
- 디스크 사용량 증가. 회전 정책 미수립 시 무한 누적.
- `log_raw=true`로 두면 평문 시크릿이 로그에 남을 수 있음 — **반드시 false 또는 미지정**.

---

### 4.5 WI-5 · OpenBao Web UI 관리자 접근

**목표**: 관리자가 시크릿을 GUI로 직접 편집 가능하게 한다.

**옵션 비교**:

| 옵션 | 장점 | 단점 | 권장 |
|------|------|------|------|
| A. nginx에 `/openbao/` 경로 + IP allow/deny | 추가 인프라 없음, TLS는 기존 nginx 활용 | nginx 설정 복잡, 잘못 노출 시 root token 입력 화면 그대로 노출 | △ |
| **B. SSH 포트포워딩 (`ssh -L 8200:localhost:8200`) 안내만** | 추가 노출 없음, 가장 안전 | 매번 터널 필요, GUI 사용성 ↓ | ★ 권장 (PoC) |
| C. 관리자 VPN 내부망 | 환경적으로 가장 안전 | VPN 인프라 필요 | 운영 시 |

**권장**: **B** (운영 가이드에 절차만 명시) → C (운영 단계).

**구현 단계 (옵션 B의 경우)**:
- `docs/guides/admin-guide.md`에 SSH 포트포워딩 절차 추가:
  ```bash
  ssh -L 8200:localhost:8200 user@gateway-host
  # 브라우저 → http://localhost:8200/ui → root token 입력
  ```
- 추가 코드 변경 없음.

**구현 단계 (옵션 A의 경우 — 운영 결정 시)**:
- `nginx/nginx.conf`에 추가:
  ```nginx
  location /openbao/ {
    allow 10.0.0.0/8;          # 사내 IP만
    deny all;
    proxy_pass http://openbao:8200/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
  }
  ```
- OpenBao 설정에서 `ui = true` 확인 (`openbao/config/openbao.hcl`).

**DoD (옵션 B)**:
- [ ] admin-guide.md에 포트포워딩 1줄 명령 등록

**DoD (옵션 A)**:
- [ ] 사내 IP에서 `https://<host>/openbao/ui` 접근 시 OpenBao UI 표시
- [ ] 사외 IP에서 403 반환

---

### 4.6 WI-6 · SSO 활성화 + 사용자 셀프서비스

**목표**: 사용자가 IdP 로그인으로 UI에 진입하여 본인 Virtual Key를 셀프서비스로 발급/재발급.

**전제**: §3에 따라 SSO 도입은 **③④⑤와 직교**. 본 WI는 사용자 운영 부담 감소가 주 목적이며, 시크릿 보안과 무관.

**변경 범위**:
- `.env` — `GENERIC_*` 항목을 사내 IdP 값으로 채움
- `docker-compose.sso.yml` — 자동 머지됨 (start.sh가 `GENERIC_CLIENT_ID` 존재 시 포함)
- `scripts/03-register-users.sh` — 사용자 사전등록 유지 (모델 매핑/한도 정의), Virtual Key 일괄 발급은 **선택적**으로 비활성화
- 운영 가이드 — 사용자 onboarding 흐름 변경

**구현 단계**:

1. IdP 측 OIDC 클라이언트 등록 (Keycloak/Okta/Azure AD 등):
   - Redirect URI: `https://<gateway>/sso/callback`
   - 그룹/role을 claim에 포함

2. `.env` 채움 (값은 IdP 콘솔에서):
   ```
   GENERIC_CLIENT_ID=...
   GENERIC_CLIENT_SECRET=...
   GENERIC_AUTHORIZATION_ENDPOINT=...
   GENERIC_TOKEN_ENDPOINT=...
   GENERIC_USERINFO_ENDPOINT=...
   ALLOWED_USER_EMAIL_DOMAINS=company.com
   DEFAULT_USER_ROLES_LITELLM_SSO=internal_user
   ```

3. `./start.sh` — 자동으로 `docker-compose.sso.yml` 머지.

4. 사용자 흐름 변경:
   - 관리자: `users.conf`에 SLOT/EMAIL/NAME 등록 → 사전 정의된 모델/한도 부여
   - 사용자: `https://<gateway>/sso/login` → IdP 로그인 → 본인 페이지에서 "Generate New Key" → 24h Virtual Key 발급 → 본인 클립보드로 복사
   - `sample-keys.txt` 일괄 배포 단계 폐지 가능

5. `03-register-users.sh`의 옵션 처리:
   - 환경변수 `SKIP_KEY_GENERATION=1`이면 사용자만 등록하고 Virtual Key는 발급하지 않음
   - SSO 활성 환경에서 cron으로 매일 키 일괄 발급할 필요 없음

**검증**:
- [ ] `https://<gateway>/sso/login` → IdP 로그인 → 본인 이메일로 LiteLLM 진입
- [ ] 본인의 모델 매핑(userNN-*)만 보임
- [ ] 본인 Virtual Key 발급/삭제 가능
- [ ] 다른 사용자의 Virtual Key는 보이지 않음

**DoD**:
- [ ] SSO 로그인 1명 성공
- [ ] 사용자가 본인 키 발급 → Codex CLI에서 작동
- [ ] 관리자 UI는 여전히 Master Key로 접근 가능
- [ ] 통합 테스트 6/6 통과 (SSO 비활성/활성 양쪽)

**위험**:
- IdP의 group/role claim 포맷 차이로 RBAC 매핑 실패 가능. `GENERIC_USER_ROLE_JWT_FIELD=groups` 등 정확한 필드 매핑 검증 필요.
- 사용자 자율 키 발급 → 한도 초과 위험. `max_budget_per_internal_user` 정책으로 보호.

---

## 5. 우선순위 및 의존성

```
                ┌──────────────────────────────────┐
                ▼                                  │
            WI-1 (AppRole) ────► WI-2 (vault-agent)
                                                   │
   WI-3 (IP 바인딩)  ─ 독립 ───────────────────────┤
                                                   │
   WI-4 (Audit log)  ─ 독립 ───────────────────────┤
                                                   │
   WI-5 (UI 접근)    ─ 독립 ───────────────────────┤
                                                   │
   WI-6 (SSO)        ─ 독립 ───────────────────────┘
```

| 권장 순서 | WI | 이유 |
|----------|----|----|
| **1** | WI-1 (AppRole) | 가장 큰 보안 갭(③), 후속 WI-2의 전제 |
| **2** | WI-3 (IP 바인딩) | 작은 변경량, 즉각적 보안 효과 (도난 키 차단) |
| **3** | WI-4 (Audit log) | 운영 추적성 확보, 변경량 작음 |
| **4** | WI-2 (vault-agent) | `.env` 평문 캐시 단계 제거. 가장 큰 아키텍처 변화 |
| **5** | WI-5 (UI 접근) | 운영 편의 |
| **6** | WI-6 (SSO) | 사용자 운영 부담 해소. 시점은 IdP 협의 진척에 따라 |

---

## 6. 결정 필요 사항 (Open Questions)

| # | 질문 | 결정자 | 마감 |
|---|------|--------|------|
| Q1 | LiteLLM Enterprise 라이선스 도입 여부 | 사업/예산 | WI-2 착수 전 |
| Q2 | 사용자별 IP/CIDR 수집 방법 (DHCP 매핑 / 사용자 신청 / 사내망 일괄) | 운영 정책 | WI-3 착수 전 |
| Q3 | OpenBao audit log 보존 기간 (30d / 90d / 1y) | 보안 정책 | WI-4 착수 전 |
| Q4 | OpenBao Web UI 노출 방식 (옵션 B SSH / 옵션 A nginx / 옵션 C VPN) | 보안 정책 | WI-5 착수 전 |
| Q5 | SSO IdP 종류 (Keycloak / Okta / Azure AD / 사내 자체) | 인프라 | WI-6 착수 전 |

---

## 7. 비범위 (Out of Scope)

- **Dynamic OpenAI API key rotation** — OpenAI API는 자동 회전을 노출하지 않음. 회전은 항상 콘솔 수작업 + WI-1 시크릿 갱신.
- **OpenBao transit engine** (애플리케이션 데이터 암호화) — 본 게이트웨이 범위 외.
- **OpenBao HA 클러스터 / 다중 리전** — PoC는 단일 노드. 운영 단계에서 별도 설계.
- **사용자별 사용량 알림 / 슬랙 봇 자동 통보** — 모니터링 영역, 별도 서비스.
- **OpenAI 외 다른 LLM 제공자(Anthropic / Bedrock 등)** — `litellm/config.yaml` 확장으로 가능하나 본 문서 비범위.

---

## 8. 참조

- 본 PoC 구현 현황: [D3-implementation-plan.md](D3-implementation-plan.md)
- v2 시스템 요구사항(SSO 통합 모델): [D2-system-requirements.md](D2-system-requirements.md)
- 운영 가이드: [docs/guides/admin-guide.md](../guides/admin-guide.md)
- 비밀 파일 가이드: [docs/operations/secrets-and-config.md](../operations/secrets-and-config.md)
- LiteLLM `/key/generate` API: 공식 문서의 Virtual Keys 섹션 (`allowed_ips`, `metadata`, `duration` 등)
- OpenBao AppRole 문서: HashiCorp Vault AppRole 문서와 호환 (CLI는 `bao` 사용)
- vault-agent 템플릿 문법: consul-template과 호환

---

## 부록 A — 현재 vs 목표 데이터 흐름 비교

### 현재 (PoC, 본 D4 작성 시점)

```
[OpenAI 콘솔] ──Key(C)── 관리자 수작업
                            │
                            ▼ set-openai-key.sh (root_token)
                       [OpenBao]
                            │
                            ▼ 02-load-secrets.sh (root_token, KV read)
                       [.env (평문, chmod 600)]
                            │
                            ▼ docker-compose env_file
                       [LiteLLM 컨테이너 OS env]

[관리자 Master Key] ──/key/generate (모델, TTL, user_id)──► Virtual Key(L)
                                                              │
                                                              ▼
                                                       sample-keys.txt
                                                              │
                                                              ▼ 안전 채널
                                                          사용자
```

### 목표 (WI-1 + WI-2 + WI-3 + WI-4 적용 후)

```
[OpenAI 콘솔] ──Key(C)── 관리자 수작업
                            │
                            ▼ set-openai-key.sh (writer-AppRole)
                       [OpenBao] ◄──────────────── audit.log
                            │
                            │ AppRole(reader) 자동 인증
                            ▼ vault-agent (sidecar)
                       [/run/secrets/litellm.env (tmpfs, 0600)]
                            │
                            ▼ docker-compose env_file
                       [LiteLLM 컨테이너 OS env]
                            │ (키 변경 시 watchdog → 컨테이너 재기동)

[관리자 Master Key] ──/key/generate (모델, TTL, user_id, allowed_ips)──► Virtual Key(L)
                                                                          │
                                                                          ▼
                                                                   sample-keys.txt
                                                                          │
                                                                          ▼
                                                                       사용자 (IP 바인딩됨)
```

### 목표 (위 + WI-6 SSO 적용 후)

```
… (위와 동일) …

[사용자] ──IdP 로그인──► LiteLLM /sso/login ──► 본인 페이지
                                                  │
                                                  ▼ /key/generate (allowed_ips는 SSO claim 또는 자동 감지)
                                               Virtual Key(L)
                                                  │
                                                  ▼ 본인이 클립보드로 복사 → Codex CLI
```

이 단계까지 완료되면 사례 ①~⑦에 대해 **③(부분 — `set-openai-key.sh`는 root)** 와 **④(부분 — `/run/secrets`에 평문 캐시)** 만 LiteLLM OSS 한계로 남고, 나머지는 사례와 동등 수준에 도달한다.
