# 개인 개발 환경 — Codex ↔ LLM Access Gateway TLS 가이드

`./start.sh` 한 번으로 Codex CLI 가 `https://localhost/v1` 을 통해 게이트웨이에 접속할 수 있도록 만들기 위한 TLS 관련 배경 + 검증 + 문제 해결 가이드.

운영(사내 CA) 환경 가이드는 [`guides/internal-ca-certificate-guide.md`](guides/internal-ca-certificate-guide.md) 참고.

---

## 1. 한 줄 요약

`./start.sh` 가 자동으로 **Local Dev Root CA + 그 CA로 서명된 leaf 서버 cert** 두 장을 만들고 Root CA 만 OS trust store 에 등록한다.
사용자는 `~/.codex/config.toml` 에 base URL/모델만 적고 Virtual Key 를 환경변수로 두면 끝.

---

## 2. 왜 단일 self-signed cert 으로는 Codex 가 동작하지 않나

이전 버전 `start.sh` 는 `openssl req -x509 …` 한 줄로 단일 self-signed cert 을 만들었다. 이 방식은 `curl -k` 나 브라우저 예외 허용에는 충분하지만 Codex CLI(v0.130 계열, rustls 기반)에서는 다음 두 에러를 낸다.

### `invalid peer certificate: UnknownIssuer`

cert 발급자가 OS / rustls trust store 어디에도 없어서 검증이 실패한다는 뜻. self-signed cert 자체가 issuer 이므로 그것이 trust store 에 직접 등록되지 않으면 신뢰 사슬이 끊어진다.

### `invalid peer certificate: Other(OtherError(CaUsedAsEndEntity))`

이게 더 까다로운 에러다. rustls 는 webpki 단계에서 다음을 검사한다.

> "지금 서버가 들이민 cert 의 `basicConstraints` 에 `CA:TRUE` 가 박혀 있는가?  
> 그렇다면 이건 *CA 용 cert* 이지 *end-entity(서버) cert* 이 아니다 → 거부."

`openssl req -x509` 의 기본 동작은 `CA:TRUE` 플래그가 포함된 cert 을 만든다. 그 한 장을 OS trust store 에 직접 등록하면 사용자 입장에서는 "내가 신뢰하는 CA" 가 되어 검증이 통과될 것 같지만, 같은 cert 이 Nginx 서버 cert(=leaf)으로도 동시에 사용되므로 rustls 가 *CA 가 leaf 자리에 와 있다* 며 거부한다. `disable_ssl_verification` 같은 옵션을 켜도 이 단계는 webpki 가 cert 을 파싱하는 시점이라 일부 구현에서 끊긴다.

→ 두 역할(CA vs server)을 *서로 다른 cert* 으로 분리해야 한다.

---

## 3. 새 구조 — Root CA + 서명된 leaf

```
                        ┌─────────────────────────────┐
                        │ local-root-ca.crt           │   ← OS trust store 에 등록
   trust 등록 대상 →   │ (CN=Local Dev Root CA,      │     (sudo update-ca-certificates)
                        │  CA:TRUE, keyCertSign)      │
                        └──────────────┬──────────────┘
                                        │ 서명 (sign)
                                        ▼
                        ┌─────────────────────────────┐
                        │ server.crt                  │   ← Nginx 가 로딩
   Nginx 가 들이미는    │ (CN=localhost,              │
   end-entity cert →    │  CA:FALSE,                  │
                        │  EKU: serverAuth,           │
                        │  SAN: DNS:localhost,        │
                        │       IP:127.0.0.1)         │
                        └─────────────────────────────┘
```

| 파일 | 역할 | trust store 등록? |
|---|---|---|
| `nginx/certs/local-root-ca.crt` | Local Dev Root CA (CA:TRUE) | **✓ 등록** |
| `nginx/certs/local-root-ca.key` | Root CA 개인키 (chmod 600) | ✗ |
| `nginx/certs/server.crt` | Nginx 서버 cert (CA:FALSE, CA로 서명됨) | **✗ 절대 등록 금지** |
| `nginx/certs/server.key` | 서버 개인키 (chmod 600) | ✗ |
| `nginx/certs/server.csr` | CSR (생성 후 그대로 둠, 재서명 시 재사용) | ✗ |
| `nginx/certs/server-openssl.cnf` | CSR config | ✗ |
| `nginx/certs/server-ext.cnf` | 서명 extensions (SAN/EKU/Basic) | ✗ |
| `nginx/certs/local-root-ca.srl` | openssl 시리얼 카운터 | ✗ |

> ⚠️ **`server.crt` 를 trust store 에 등록하지 말 것.**
> 등록하면 OS는 그것을 "신뢰하는 CA" 로 취급하는데 동시에 같은 cert 이 Nginx 서버 cert 으로 들이밀리므로 `CaUsedAsEndEntity` 가 되돌아온다. 등록 대상은 **항상 `local-root-ca.crt` 한 장만**.

---

## 4. start.sh 의 동작 흐름

`./start.sh` 의 Phase 1 (Bootstrap) 안 `ensure_dev_tls_cert` 함수가 다음을 수행한다.

```
┌─────────────────────────────────────────────────────────────────┐
│ ensure_dev_tls_cert                                              │
├─────────────────────────────────────────────────────────────────┤
│ 1. USE_EXISTING_TLS_CERT=true 이면 무조건 보존 → return          │
│ 2. is_production_cert: issuer 가 "Local Dev Root CA" 아니면      │
│    사내 운영 cert으로 간주 → 덮어쓰지 않고 return                │
│ 3. is_valid_dev_cert:                                            │
│       SAN(DNS:localhost,IP:127.0.0.1), Basic Constraints,        │
│       EKU(serverAuth), issuer chain 모두 정상이면 → 유지         │
│       하나라도 어긋나면 generate_dev_tls_cert 호출 (재생성)      │
│ 4. install_local_root_ca_if_possible:                            │
│       AUTO_INSTALL_DEV_CA=true (기본) 이면                       │
│       /usr/local/share/ca-certificates 로 sudo cp +              │
│       sudo update-ca-certificates                                 │
│       (sudo 실패/취소 시 안내만 출력하고 start.sh 는 계속 진행)  │
└─────────────────────────────────────────────────────────────────┘
```

또한 인증서가 *이번 run에서 재생성*되었으면 Phase 5에서 nginx 컨테이너를 자동 재시작해 새 cert 을 즉시 반영한다.

### 환경변수

| 변수 | 기본값 | 설명 |
|---|---|---|
| `AUTO_INSTALL_DEV_CA` | `true` | `false` 로 두면 sudo 시도 없이 안내 메시지만 출력 (CI/무인 환경용) |
| `USE_EXISTING_TLS_CERT` | `false` | `true` 로 두면 cert 파일이 어떤 상태이든 덮어쓰지 않음 |

---

## 5. 검증 명령

cert 자체 검사:

```bash
# 1) issuer / subject
openssl x509 -in nginx/certs/server.crt -noout -issuer -subject
# 기대:
#   issuer=C=KR, O=PoC, CN=Local Dev Root CA
#   subject=C=KR, O=PoC, CN=localhost

# 2) SAN 확인
openssl x509 -in nginx/certs/server.crt -noout -text | grep -A 1 "Subject Alternative Name"
# 기대: DNS:localhost, IP Address:127.0.0.1

# 3) Basic Constraints — CA:FALSE 여야 함
openssl x509 -in nginx/certs/server.crt -noout -text | grep -A 1 "Basic Constraints"
# 기대: CA:FALSE  (CA:TRUE 가 있으면 잘못된 cert)

# 4) Extended Key Usage — serverAuth 필수
openssl x509 -in nginx/certs/server.crt -noout -text | grep -A 1 "Extended Key Usage"
# 기대: TLS Web Server Authentication

# 5) trust chain — verify
openssl verify -CAfile nginx/certs/local-root-ca.crt nginx/certs/server.crt
# 기대: nginx/certs/server.crt: OK
```

HTTPS 동작 (CA 가 OS 에 등록되어 있어야 `-k` 없이 통과):

```bash
# 모델 목록
curl https://localhost/v1/models \
  -H "Authorization: Bearer $OPENAI_API_KEY" | jq .

# Responses API (Codex 가 사용하는 엔드포인트)
curl -X POST https://localhost/v1/responses \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"user01-gpt-4o","input":"hi"}'

# Chat Completions
curl -X POST https://localhost/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"user01-gpt-4o","messages":[{"role":"user","content":"hi"}]}'
```

`-k` 없이 셋 다 200 이 떨어지면 cert + trust 가 정상.
`-k` 가 있어야만 통과한다면 **trust store 에 CA 가 안 들어갔다** — §6 참고.

`tests/09-test-dev-tls-cert.sh` 가 (1)~(4) 와 chain 검증을 자동화한다.

---

## 6. Codex 설정

`~/.codex/config.toml`:

```toml
model_provider  = "openai"
openai_base_url = "https://localhost/v1"
model           = "user01-gpt-4o"
approval_mode   = "suggest"
```

환경변수에 Virtual Key:

```bash
# scripts/sample-keys.txt 한 줄의 4번째 컬럼이 키
export OPENAI_API_KEY=$(grep '^alice@local ' scripts/sample-keys.txt | awk '{print $4}')

codex
```

### 로그인 화면이 뜨면

> **"Provide your own API key"** 를 선택하고 위 `$OPENAI_API_KEY` (sk-... 으로 시작) 를 붙여넣는다.
>
> **"Sign in with ChatGPT" 는 절대 선택하지 말 것.** ChatGPT 로그인은 OAuth 가 발급한 `eyJh...` 형태의 JWT 베어러 토큰을 보내는데, LiteLLM 은 Virtual Key 만 받는다. 다음과 같은 에러가 난다:
>
> ```
> Authentication Error: Invalid proxy server token passed.
> Expected to start with sk-.
> ```

---

## 7. 트러블슈팅

### Q. `curl https://localhost/...` 가 self-signed certificate 에러를 낸다

→ CA 가 OS trust store 에 등록되지 않은 상태. 다음을 1회 실행:

```bash
sudo cp nginx/certs/local-root-ca.crt /usr/local/share/ca-certificates/llm-access-gateway-local-root-ca.crt
sudo update-ca-certificates
```

다른 OS:
- **macOS**: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain nginx/certs/local-root-ca.crt`
- **Fedora/RHEL**: `sudo cp nginx/certs/local-root-ca.crt /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust`
- **Arch**: `sudo trust anchor nginx/certs/local-root-ca.crt`

WSL Ubuntu 에서 Windows 의 사내 인증서를 쓰고 싶다면 Windows trust 와는 별개로 WSL 안에서 위 명령을 따로 실행해야 한다.

### Q. Codex 가 `CaUsedAsEndEntity` 를 낸다

→ `nginx/certs/server.crt` 가 *현재* CA 플래그를 들고 있다는 뜻. 다음을 확인:

```bash
openssl x509 -in nginx/certs/server.crt -noout -text | grep -A 1 "Basic Constraints"
# CA:FALSE 여야 함
```

`CA:TRUE` 가 보이면 옛 self-signed cert 가 남아있는 것. 다음으로 강제 재생성:

```bash
rm nginx/certs/local-root-ca.* nginx/certs/server.*
./start.sh
```

### Q. `./start.sh` 재실행 시 cert 가 덮어써질까 봐 걱정된다 (사내 CA 적용해둠)

→ start.sh 는 `is_production_cert` 로 issuer 를 검사한다. `Local Dev Root CA` 가 아니면 자동으로 보존한다. 더 확실히 잠그려면:

```bash
export USE_EXISTING_TLS_CERT=true
./start.sh
```

### Q. Codex 가 `Model metadata for user01-gpt-4o not found` 경고를 낸다

→ LiteLLM 모델 alias (`user01-gpt-4o` 같은 슬롯 prefix) 가 Codex CLI 의 내장 모델 catalog 에 없어서 fallback metadata 를 쓴다는 경고. **동작은 정상**. 정확한 토큰 카운트 등이 안 보일 수 있는 정도.

해결하려면 `~/.codex/<your-catalog>.json` 에 alias 를 추가하고 `model_catalog_json` 으로 지정.

### Q. Codex 가 `Falling back from WebSockets to HTTPS transport` 와 함께 동작은 한다

→ Codex 는 먼저 `wss://.../v1/responses` 로 시도하는데 LiteLLM 이 WebSocket 업그레이드를 처리하지 않으므로 405/501 으로 거부 → Codex 가 자동으로 HTTPS 로 fallback. **fallback 으로 응답이 오면 치명적 오류가 아니다**. WebSocket native 지원이 필요하면 LiteLLM 업그레이드 추적.

### Q. 사내망에서 `https_proxy` 가 설정되어 있어 transparent proxy 가 끼어든다

→ `NO_PROXY` 에 `localhost,127.0.0.1` 그리고 게이트웨이 IP 를 추가:

```bash
export NO_PROXY="${NO_PROXY},localhost,127.0.0.1,<gateway-ip>"
export no_proxy="${no_proxy},localhost,127.0.0.1,<gateway-ip>"
```

---

## 8. 운영 인증서로 교체할 때

사내 CA 발급 cert 으로 교체하는 정식 절차는 [`guides/internal-ca-certificate-guide.md`](guides/internal-ca-certificate-guide.md) 참고. 핵심:

1. 사내 CA 가 서명한 fullchain → `nginx/certs/server.crt`
2. 그에 대응하는 개인키 → `nginx/certs/server.key`
3. `./start.sh` 재실행 — `is_production_cert` 가 issuer 를 보고 자동으로 보존 (덮어쓰지 않음).

start.sh 는 issuer 가 `Local Dev Root CA` 일 때만 dev cert 으로 인식한다. 사내 CA 가 서명한 cert 은 issuer 가 그 사내 CA 가 되므로 자동 보존된다.

---

## 9. 보안 주의

- `local-root-ca.key`, `server.key` 는 `chmod 600`. 절대 commit 금지 (`.gitignore` 처리됨).
- `local-root-ca.crt` 는 *개발자 본인 머신에서만* 신뢰돼야 한다. 다른 사람의 trust store 에 배포하지 말 것 — 그 사람의 모든 HTTPS 트래픽에 대해 당신이 leaf cert 을 발급할 수 있는 권한이 생긴다.
- Virtual Key (`scripts/sample-keys.txt`) 는 DO NOT COMMIT. `.gitignore` 처리됨.
- 운영 환경에서는 이 dev cert 흐름을 사용하지 말고 사내 CA 발급 cert 으로 교체할 것.
