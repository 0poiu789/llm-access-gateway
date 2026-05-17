# 사내 CA 인증서 적용 가이드

## 1. 목적

본 문서는 `llm-access-gateway`를 사내 HTTPS 서비스로 운영하기 위해 필요한 **사내 DNS 등록** 및 **사내 CA 기반 서버 인증서 적용 절차**를 정리한다.

Codex CLI 사용자는 LiteLLM Virtual Key를 사용하여 다음 주소로 접속한다.

```text
https://llm-gateway.<사내도메인>/v1
```

최종 통신 구조는 다음과 같다.

```text
Codex CLI
  → https://llm-gateway.<사내도메인>/v1
  → Nginx
  → LiteLLM Proxy
  → OpenAI API
```

---

## 2. 왜 사내 CA 인증서가 필요한가?

Codex CLI는 `https://...` 주소로 LLM Access Gateway에 접속할 때 서버 인증서를 검증한다.

개발용 자체서명 인증서를 사용할 경우 다음과 같은 오류가 발생할 수 있다.

```text
invalid peer certificate: UnknownIssuer
invalid peer certificate: CaUsedAsEndEntity
```

`curl -k` 명령은 인증서 검증을 생략하므로 성공할 수 있지만, Codex CLI는 인증서 검증을 수행하므로 실패할 수 있다.

따라서 사내 운영 환경에서는 개발용 자체서명 인증서가 아니라, **사내에서 신뢰되는 CA가 발급한 서버 인증서**를 사용해야 한다.

---

## 3. 권장 운영 방식

예를 들어 LLM Access Gateway를 구동하는 서버의 IP가 다음과 같다고 가정한다.

```text
11.11.111.111
```

사내 운영에서는 IP를 직접 사용하는 것보다 DNS 이름을 사용하는 것을 권장한다.

```text
llm-gateway.<사내도메인> → 11.11.111.111
```

사용자는 다음 주소로 접속한다.

```text
https://llm-gateway.<사내도메인>/v1
```

Codex 설정 예시는 다음과 같다.

```toml
model_provider = "openai"
openai_base_url = "https://llm-gateway.<사내도메인>/v1"
model = "user01-gpt-4o"

approval_mode = "suggest"
```

사내 모델 alias를 사용하는 경우 예시는 다음과 같다.

```toml
model_provider = "openai"
openai_base_url = "https://llm-gateway.<사내도메인>/v1"
model = "user05-gpt-5.4-cyber"

approval_mode = "suggest"
```

---

## 4. 사내 DNS 요청 사항

사내 DNS 담당 부서에 다음 등록을 요청한다.

```text
FQDN: llm-gateway.<사내도메인>
대상 IP: 11.11.111.111
레코드 유형: A record
```

예시는 다음과 같다.

```text
llm-gateway.<사내도메인>  A  11.11.111.111
```

DNS 등록 후 Gateway 서버 또는 사용자 PC에서 다음 명령으로 확인한다.

```bash
getent hosts llm-gateway.<사내도메인>
```

기대 결과:

```text
11.11.111.111  llm-gateway.<사내도메인>
```

---

## 5. 사내 CA 서버 인증서 요청 사항

사내 인증서 담당 부서에 다음 서버 인증서를 요청한다.

```text
인증서 유형: 서버 인증서
용도: Nginx HTTPS 서버 인증서
FQDN: llm-gateway.<사내도메인>
SAN: DNS:llm-gateway.<사내도메인>
형식: PEM
```

필요한 파일은 다음과 같다.

```text
1. 서버 인증서 또는 fullchain 인증서
2. 개인키 파일
3. 필요한 경우 중간 CA 체인 파일
```

가능하면 **fullchain 인증서** 형태로 받는 것을 권장한다.

```text
server certificate + intermediate CA chain
```

---

## 6. 인증서 설치 위치

LLM Access Gateway의 Nginx는 기본적으로 다음 경로의 인증서 파일을 사용한다.

컨테이너 내부 경로:

```text
/etc/nginx/certs/server.crt
/etc/nginx/certs/server.key
```

호스트 repository 기준 실제 파일 경로:

```text
nginx/certs/server.crt
nginx/certs/server.key
```

따라서 사내 CA에서 발급받은 파일을 다음과 같이 배치한다.

```text
사내 CA 발급 fullchain 인증서 → nginx/certs/server.crt
개인키 파일                  → nginx/certs/server.key
```

---

## 7. 인증서 설치 절차

Gateway 서버에서 다음을 수행한다.

```bash
cd ~/llm-access-gateway
```

기존 개발용 자체서명 인증서를 백업한다.

```bash
mkdir -p nginx/certs/backup-$(date +%Y%m%d-%H%M%S)
cp nginx/certs/server.crt nginx/certs/server.key nginx/certs/backup-$(date +%Y%m%d-%H%M%S)/
```

사내에서 받은 인증서를 설치한다.

fullchain 인증서를 받은 경우:

```bash
cp /path/to/llm-gateway-fullchain.crt nginx/certs/server.crt
cp /path/to/llm-gateway.key nginx/certs/server.key
```

서버 인증서와 CA chain을 따로 받은 경우:

```bash
cat /path/to/llm-gateway.crt /path/to/ca-chain.crt > nginx/certs/server.crt
cp /path/to/llm-gateway.key nginx/certs/server.key
```

파일 권한을 정리한다.

```bash
chmod 644 nginx/certs/server.crt
chmod 600 nginx/certs/server.key
```

Nginx 컨테이너를 재시작한다.

```bash
docker compose restart nginx
```

---

## 8. 인증서 내용 확인

인증서 subject, issuer, 만료일을 확인한다.

```bash
openssl x509 -in nginx/certs/server.crt -noout -subject -issuer -dates
```

SAN을 확인한다.

```bash
openssl x509 -in nginx/certs/server.crt -noout -text | grep -A5 "Subject Alternative Name"
```

기대값:

```text
DNS:llm-gateway.<사내도메인>
```

SAN에 접속 주소가 없으면 Codex, curl, 브라우저가 인증서를 거부할 수 있다.

---

## 9. HTTPS 동작 확인

LiteLLM Virtual Key를 환경변수로 설정한다.

```bash
export OPENAI_API_KEY="<LiteLLM Virtual Key>"
```

`-k` 옵션 없이 모델 목록을 조회한다.

```bash
curl https://llm-gateway.<사내도메인>/v1/models \
  -H "Authorization: Bearer $OPENAI_API_KEY" | jq
```

정상적으로 응답이 오면 인증서 검증이 통과한 것이다.

`curl -k`를 붙여야만 성공한다면 인증서 신뢰 체계가 아직 정상 구성되지 않은 것이다.

---

## 10. Codex 설정

사용자 PC 또는 WSL의 `~/.codex/config.toml`을 다음과 같이 설정한다.

```toml
model_provider = "openai"
openai_base_url = "https://llm-gateway.<사내도메인>/v1"
model = "user01-gpt-4o"

approval_mode = "suggest"
```

사내 모델 alias를 사용하는 경우:

```toml
model_provider = "openai"
openai_base_url = "https://llm-gateway.<사내도메인>/v1"
model = "user05-gpt-5.4-cyber"

approval_mode = "suggest"
```

Codex 실행 전에 LiteLLM Virtual Key를 설정한다.

```bash
export OPENAI_API_KEY="<LiteLLM Virtual Key>"
codex
```

여기서 사용하는 `OPENAI_API_KEY`는 실제 OpenAI API Key가 아니라 LiteLLM이 발급한 Virtual Key이다.

---

## 11. 사용자 PC에 별도 인증서 설치가 필요한가?

일반적인 사내 PC에서는 사내 Root CA가 이미 신뢰 저장소에 등록되어 있으므로 별도 설치가 필요 없다.

다만 다음 경우에는 사용자 PC 또는 WSL 환경에도 사내 Root CA 등록이 필요할 수 있다.

```text
1. WSL Ubuntu가 Windows의 사내 Root CA를 신뢰하지 않는 경우
2. 사용자 PC가 사내 Root CA를 갖고 있지 않은 경우
3. Codex CLI가 OS trust store와 다른 trust store를 사용하는 경우
```

이 경우 사내 Root CA 인증서를 WSL에 등록한다.

```bash
sudo cp <사내-root-ca.crt> /usr/local/share/ca-certificates/company-root-ca.crt
sudo update-ca-certificates
```

그 다음 `curl -k` 없이 HTTPS 호출이 되는지 확인한다.

```bash
curl https://llm-gateway.<사내도메인>/v1/models \
  -H "Authorization: Bearer $OPENAI_API_KEY" | jq
```

---

## 12. IP 주소 기반 인증서 사용 가능 여부

DNS 없이 IP 주소로도 기술적으로 가능하다.

예를 들어 다음 주소를 계속 사용하려면:

```text
https://11.11.111.111/v1
```

인증서 SAN에 다음이 포함되어야 한다.

```text
IP Address:11.11.111.111
```

하지만 사내 인증서 발급 정책상 IP SAN 인증서 발급이 제한될 수 있고, 서버 IP 변경 시 모든 사용자 설정을 바꿔야 하므로 운영 환경에서는 DNS 방식이 권장된다.

권장 방식:

```text
https://llm-gateway.<사내도메인>/v1
SAN: DNS:llm-gateway.<사내도메인>
```

---

## 13. 담당 부서 요청 문구

아래 문구를 사내 DNS/인증서 담당 부서에 전달한다.

```text
LLM Access Gateway를 사내 HTTPS 서비스로 운영하려고 합니다.

서버 IP:
11.11.111.111

요청 1. 사내 DNS 등록
- FQDN: llm-gateway.<사내도메인>
- A record: 11.11.111.111

요청 2. 사내 CA 기반 서버 인증서 발급
- 인증서 대상 FQDN: llm-gateway.<사내도메인>
- SAN: DNS:llm-gateway.<사내도메인>
- 용도: Nginx HTTPS 서버 인증서
- 형식: PEM
- 필요 파일:
  1. fullchain 인증서
  2. private key

사용 목적:
Codex CLI 사용자가 https://llm-gateway.<사내도메인>/v1 로 LiteLLM Proxy에 접속하기 위함입니다.
```

---

## 14. 요약

사내 운영을 위한 권장 구조는 다음과 같다.

```text
1. llm-gateway.<사내도메인> DNS를 만든다.
2. 해당 DNS가 Gateway 서버 IP인 11.11.111.111을 가리키게 한다.
3. 사내 CA에서 llm-gateway.<사내도메인>용 서버 인증서를 발급받는다.
4. 인증서 SAN에는 DNS:llm-gateway.<사내도메인>이 포함되어야 한다.
5. 발급받은 fullchain 인증서와 개인키를 nginx/certs/server.crt, server.key로 설치한다.
6. Nginx를 재시작한다.
7. Codex는 openai_base_url = "https://llm-gateway.<사내도메인>/v1" 로 접속한다.
8. 사용자는 실제 OpenAI API Key가 아니라 LiteLLM Virtual Key를 사용한다.
```
