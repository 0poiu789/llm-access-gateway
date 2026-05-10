# 사용자 가이드 (일반 사용자)

게이트웨이를 통해 Codex CLI / OpenAI API를 사용하는 **일반 사용자** 대상 안내서.
관리자 작업(설치·키 발급·배포)은 [admin-guide.md](admin-guide.md)에 있다.

---

## 1. 본인이 받아야 하는 것 (관리자에게)

관리자가 안전한 채널(사내 메신저 다이렉트, 회사 메일 등)로 다음 3가지를 전달한다.

| 항목 | 형태 | 예시 |
|------|------|------|
| **게이트웨이 주소** | URL | `https://10.0.1.42` 또는 `https://llm-gateway.사내도메인` |
| **Virtual Key** | `sk-vk-...` 시작 문자열 | `sk-vk-abcd...` (24시간 유효) |
| **본인 슬롯 번호** | `userNN` | `user01` ~ `user10` |

> Virtual Key는 24시간 후 자동 만료되므로 매일(또는 만료 직전) 관리자에게 새 Key를 받아 갱신한다.
> 셀프서비스 UI 로그인은 현재 PoC 단계에서 비활성화되어 있다.

---

## 2. 환경변수 1회 설정

```bash
# ~/.bashrc (또는 ~/.zshrc)에 추가
export GATEWAY_URL="https://<관리자에게_받은_서버주소>"
export OPENAI_API_KEY="sk-vk-..."   # 관리자에게 받은 본인 Virtual Key

# 적용
source ~/.bashrc
```

> 자체서명 TLS 인증서를 사용하는 환경이라면 브라우저에서는 "고급 → 진행" 클릭, `curl`은 `-k`(insecure) 옵션을 붙인다. 사내 CA 인증서로 교체된 환경이라면 그대로 사용한다.

---

## 3. 동작 확인 — 본인 정보 조회

`client-tools/check-info.sh`(관리자가 함께 전달)를 실행하면 본인 사용량 / 잔여 예산 / Key 만료 시각 / 허용 모델을 한눈에 확인할 수 있다.

```bash
cd client-tools
./check-info.sh
```

출력 예:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 LLM Access Gateway — 사용량 리포트
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Key alias:    user01-codex-20260510-145003
  사용 금액:     $0.4218
  월 한도:       $50.00  (예산 주기: 30d)
  잔여 예산:     $49.5782
  만료 시각:     2026-05-11T14:50:03+00:00 (+18.5h)
  허용 모델:     user01-gpt-4o, user01-o3-mini
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

스크립트가 없는 환경에서 직접 확인하고 싶으면:

```bash
curl -sk "$GATEWAY_URL/key/info" -H "Authorization: Bearer $OPENAI_API_KEY" | python3 -m json.tool
curl -sk "$GATEWAY_URL/v1/models" -H "Authorization: Bearer $OPENAI_API_KEY" | python3 -m json.tool
```

---

## 4. Codex CLI 연동

```bash
mkdir -p ~/.codex
cat > ~/.codex/config.toml << 'TOML'
openai_base_url = "https://<게이트웨이_주소>/v1"
model = "user01-gpt-4o"   # NN을 본인 슬롯 번호로 (관리자에게 받은 값)
approval_mode = "suggest"
TOML
```

사용:

```bash
codex                                          # 대화형 세션
codex exec "이 프로젝트의 README를 만들어줘"      # 일회성 명령
```

> 본인에게 할당되지 않은 모델(`userZZ-*`)을 호출하면 거부된다. 정상 동작이며, 본인의 `userNN-gpt-4o` / `userNN-o3-mini` 만 사용 가능하다.

---

## 5. OpenAI SDK / 일반 API에서 사용

게이트웨이는 OpenAI 호환이므로 `OPENAI_BASE_URL` + `OPENAI_API_KEY` 두 변수만 본인 값으로 두면 그대로 쓸 수 있다.

```python
from openai import OpenAI
client = OpenAI(
    base_url=f"{os.environ['GATEWAY_URL']}/v1",
    api_key=os.environ["OPENAI_API_KEY"],
)
resp = client.chat.completions.create(
    model="user01-gpt-4o",  # 본인 슬롯 모델
    messages=[{"role": "user", "content": "hello"}],
)
```

> 자체서명 TLS인 경우에는 `httpx.Client(verify=False)`를 SDK에 주입하거나 사내 CA 번들을 `SSL_CERT_FILE`로 지정한다.

---

## 6. 자주 묻는 질문

**Q. 401 / "Invalid API key" 가 떠요.**
Virtual Key가 만료(24h) 되었거나, `OPENAI_API_KEY` 환경변수에 따옴표/공백이 섞였을 수 있다. `./check-info.sh`로 만료 시각을 우선 확인하고, 만료라면 관리자에게 새 Key를 요청한다.

**Q. 어떤 모델을 호출할 수 있나요?**
본인 슬롯에 매핑된 두 모델만 가능하다 — `userNN-gpt-4o`, `userNN-o3-mini`. 그 외 모델 이름(예: `gpt-4o` 직접)은 거부된다.

**Q. UI(`https://<게이트웨이>/ui`)에 본인 계정으로 로그인하고 싶어요.**
현재 PoC는 관리자 전용 UI다. 사용자 본인 정보는 `check-info.sh` 또는 `/key/info` API로 조회한다. SSO가 활성화된 환경에서는 사내 IdP 로그인으로 셀프서비스 UI가 열리지만, PoC 기본 설정에서는 비활성이다.

**Q. `CONNECTION_REFUSED` / TLS 경고.**
- TLS 경고: 자체서명이면 정상이며 `curl -k` 또는 브라우저 예외 추가.
- `CONNECTION_REFUSED`: `GATEWAY_URL`이 잘못됐거나 게이트웨이가 내려가 있을 가능성. 관리자에게 정확한 주소와 상태를 확인.

**Q. 사용량 / 잔여 예산은 어디까지 소진하면 되나요?**
기본값은 30일 주기로 $50 한도. 한도에 가까워지면 호출이 거부되며, 관리자가 한도를 조정해야 한다.

---

## 7. 관련 파일

- `client-tools/check-info.sh` — 본인 정보 조회 스크립트 (배포본)
- `client-tools/README.md` — 클라이언트 도구 단독 README
