# Client Tools — 사용자 배포용 스크립트

게이트웨이 사용자가 본인 PC에 두고 사용하는 도구 모음. 관리자가 사용자에게 Virtual Key와 함께 이 디렉토리(또는 `check-info.sh` 파일)를 전달.

## 사전 준비

```bash
# 1) 게이트웨이 주소를 환경변수로 (한 번만)
echo 'export GATEWAY_URL="https://<관리자에게_받은_서버주소>"' >> ~/.bashrc

# 2) Virtual Key (24시간 유효, 만료 시 관리자에게 새 키 요청)
echo 'export OPENAI_API_KEY="sk-vk-..."' >> ~/.bashrc

source ~/.bashrc
```

## 도구

### `check-info.sh` — 본인 사용량 / 잔여 예산 / 만료 시각 조회

```bash
./check-info.sh
```

출력 예:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 LLM Access Gateway — 사용량 리포트
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Key alias:    user01-codex-20260508-145003
  사용 금액:     $0.4218
  월 한도:       $50.00  (예산 주기: 30d)
  잔여 예산:     $49.5782
  만료 시각:     2026-05-09T14:50:03+00:00 (+18.5h)
  허용 모델:     user01-gpt-4o, user01-o3-mini
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Codex CLI 연동

```bash
mkdir -p ~/.codex
cat > ~/.codex/config.toml << 'TOML'
openai_base_url = "https://<게이트웨이_주소>/v1"
model = "user01-gpt-4o"   # XX는 관리자에게 받은 본인 슬롯 번호
approval_mode = "suggest"
TOML

# 사용
codex                                        # 대화형
codex exec "이 프로젝트의 README를 만들어줘"  # 일회성
```

## 자주 묻는 질문

**Q. 24시간 후 Key가 만료됐어요.**
관리자가 매일 (또는 필요 시) `./start.sh`를 재실행하면 새 24h Key가 발급됩니다. 관리자에게 본인의 새 Key를 요청하고 `OPENAI_API_KEY` 환경변수를 갱신하세요.

**Q. UI(`https://<게이트웨이>/ui`)에 로그인할 수 있나요?**
현재 PoC는 관리자만 UI에 접근합니다. 사용자는 본인 정보를 `check-info.sh`로 조회하면 됩니다. 향후 SSO 도입 시 UI 셀프서비스가 활성화됩니다.

**Q. `CONNECTION_REFUSED` / TLS 경고가 떠요.**
- 자체서명 인증서로 시작했으면 브라우저는 "고급 → 진행" 클릭, curl은 `-k` 사용.
- `CONNECTION_REFUSED`는 `GATEWAY_URL` 값이 잘못됐을 가능성 — 관리자에게 정확한 IP/도메인 확인.

**Q. 다른 사용자의 모델로 호출 시도 시 거부됩니다.**
정상 동작입니다. 본인에게 할당된 모델(`userXX-*`)만 호출 가능합니다.
