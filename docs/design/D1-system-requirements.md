# 목차

- 1. 개요
- 2. Phase 1 — 디렉토리 및 Docker Compose 구성
- 3. Phase 2 — OpenBao 초기화 및 사용자별 API Key 저장
- 4. Phase 3 — LiteLLM Proxy 구성 (사용자-모델 매핑)
- 5. Phase 4 — 시스템 기동 및 검증
- 6. Phase 5 — 사용자별 Virtual Key 발급
- 7. Phase 6 — Codex CLI 사용자 설정 가이드
- 8. 사용량 모니터링
- 9. 입출력 로그 관리 (관리자 전용)
- 10. 운영 가이드
- 11. 보안 체크리스트
- 12. 트러블슈팅
- 13. 접속 정보 요약
- 14. 참고자료

---

# 1. 개요

본 문서는 Linux 환경에서 **OpenBao**(시크릿 저장소)와 **LiteLLM Proxy**(AI 게이트웨이)를 연동하여 **10명의 사용자가 각각 고유한 OpenAI API Key로 Codex CLI를 사용**할 수 있는 시스템을 구축하는 절차를 기술한다.

> **핵심 요구사항**
>
> | # | 요구사항 | 구현 방법 |
> |---|---------|----------|
> | 1 | 각 사용자(최대 10명)는 고유 Virtual Key로 LiteLLM에 접근 | LiteLLM `/key/generate` API로 사용자별 Virtual Key 발급 |
> | 2 | 각 Virtual Key는 각각 고유한 OpenAI API Key에 매핑 | 사용자별 전용 모델 항목 정의 + Virtual Key의 `models` 제한 |
> | 3 | 사용자는 Virtual Key로 사용 내역 모니터링 가능 | `/key/info` API 엔드포인트 + 모니터링 스크립트 제공 |
> | 4 | 사용자는 Codex CLI 전용으로만 접근 | Codex CLI `config.toml`에 LiteLLM Proxy 연결 설정 |
> | 5 | Admin UI는 관리자만 접근, 일반 사용자 접근 차단 | Nginx 리버스 프록시로 `/ui` 경로 IP 제한 |
> | 6 | 관리자는 각 사용자의 입출력 로그 히스토리를 관리/모니터링 | `store_prompts_in_spend_logs: true` 설정 + Admin UI Logs 탭 + `/spend/logs` API |
> | 7 | 일반 사용자는 입출력 로그 히스토리를 볼 수 없음 | Nginx 포트 80에서 `/spend/*`, `/global/spend/*` 경로 차단 |

## 1.1. 사용자-Key 매핑 구조

각 사용자의 Virtual Key가 고유한 OpenAI API Key에 매핑되는 구조를 아래 다이어그램으로 설명한다.

**사용자별 Key 매핑 흐름**

```text

  사용자 PC (Codex CLI)              LiteLLM Proxy                OpenBao                   OpenAI API
  ─────────────────────          ─────────────────────       ─────────────────────      ─────────────────
                                                                                        
  User01 ──► Virtual Key A ──►   model: "user01-gpt-4o" ──► USER01_OPENAI_KEY ──────►  api.openai.com
  User02 ──► Virtual Key B ──►   model: "user02-gpt-4o" ──► USER02_OPENAI_KEY ──────►  api.openai.com
  User03 ──► Virtual Key C ──►   model: "user03-gpt-4o" ──► USER03_OPENAI_KEY ──────►  api.openai.com
   ...                            ...                         ...
  User10 ──► Virtual Key J ──►   model: "user10-gpt-4o" ──► USER10_OPENAI_KEY ──────►  api.openai.com
  
  ※ 각 Virtual Key는 자신의 모델 항목에만 접근 가능 (models 제한)
  ※ 각 모델 항목은 OpenBao에 저장된 해당 사용자의 OpenAI Key를 사용
  ※ 실제 OpenAI API Key는 사용자에게 절대 노출되지 않음
```

## 1.2. 시스템 구성요소

| 구성요소 | 역할 | 포트 | Docker 이미지 |
|---------|------|------|--------------|
| **Nginx** | 리버스 프록시, Admin UI 접근 제한 | 80 (API), 8443 (Admin) | `nginx:alpine` |
| **LiteLLM Proxy** | 통합 LLM 게이트웨이, Virtual Key 관리, 사용량 추적 | 4000 (내부) | `docker.litellm.ai/berriai/litellm-database:main-latest` |
| **OpenBao** | 10개 OpenAI API Key 암호화 저장, 접근 제어 | 8200 (내부) | `openbao/openbao:latest` |
| **PostgreSQL** | Virtual Key 메타데이터, 사용량/비용 기록 | 5432 (내부) | `postgres:16-alpine` |

---

# 2. Phase 1 — 디렉토리 및 Docker Compose 구성

## 2.1. 디렉토리 구조 생성

```bash
mkdir -p ~/llm-gateway/{openbao/{config,data,logs},litellm,postgres,nginx}
cd ~/llm-gateway
```

## 2.2. 환경변수 파일 생성

**.env 파일**

```bash
cat > .env << 'EOF'
# ── PostgreSQL ──
POSTGRES_PASSWORD=Change_This_Strong_Password_123!

# ── LiteLLM ──
LITELLM_MASTER_KEY=sk-master-change-me-to-random-string

# ── OpenBao (Phase 2에서 채움) ──
OPENBAO_ROOT_TOKEN=

# ── Admin UI 접근 허용 IP (CIDR) ──
ADMIN_ALLOW_IP=10.0.0.0/8
EOF

chmod 600 .env
```

## 2.3. OpenBao 설정 파일

**openbao/config/openbao.hcl**

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

## 2.4. Nginx 리버스 프록시 설정 (Admin UI 접근 제한)

> **ℹ️ Admin UI 접근 제한 방식**
>
> Nginx를 리버스 프록시로 배치하여 두 개의 접근 경로를 분리한다.
>
> - **포트 80** — 일반 사용자용: `/v1/*`, `/key/info`, `/health` 엔드포인트만 허용. `/ui`, `/key/generate`, `/key/delete`, `/spend/*` 등 관리 경로 및 로그 조회 경로는 차단.
> - **포트 8443** — 관리자 전용: 모든 LiteLLM 경로 허용. 지정된 관리자 IP에서만 접근 가능.

**nginx/nginx.conf**

```bash
cat > nginx/nginx.conf << 'NGINX'
worker_processes auto;
events { worker_connections 1024; }

http {
    # ── 공통 설정 ──
    upstream litellm_backend {
        server litellm:4000;
    }

    # ══════════════════════════════════════════════
    # 포트 80: 일반 사용자용 (Codex CLI 접근)
    # API 엔드포인트만 허용, Admin 경로 차단
    # ══════════════════════════════════════════════
    server {
        listen 80;
        server_name _;

        # ── 허용: OpenAI-compatible API 엔드포인트 ──
        location /v1/ {
            proxy_pass http://litellm_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;

            # SSE (Server-Sent Events) 지원 — Codex 스트리밍에 필요
            proxy_buffering off;
            proxy_cache off;
            chunked_transfer_encoding on;
        }

        # ── 허용: 사용량 조회 (Virtual Key 소유자만 자신의 정보 열람 가능) ──
        location /key/info {
            proxy_pass http://litellm_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        # ── 허용: 헬스체크 ──
        location /health {
            proxy_pass http://litellm_backend;
        }

        # ── 차단: Admin UI ──
        location /ui {
            return 403 '{"error": "Access denied. Admin UI is not accessible from this port."}';
            add_header Content-Type application/json;
        }

        # ── 차단: Key 관리 API (generate, delete, update, block) ──
        location ~ ^/key/(generate|delete|update|block|unblock) {
            return 403 '{"error": "Access denied. Key management requires admin access."}';
            add_header Content-Type application/json;
        }

        # ── 차단: 입출력 로그 조회 API (관리자 전용) ──
        location /spend {
            return 403 '{"error": "Access denied. Log history requires admin access."}';
            add_header Content-Type application/json;
        }

        location /global/spend {
            return 403 '{"error": "Access denied. Log history requires admin access."}';
            add_header Content-Type application/json;
        }

        # ── 차단: 그 외 모든 경로 ──
        location / {
            return 403 '{"error": "Access denied."}';
            add_header Content-Type application/json;
        }
    }

    # ══════════════════════════════════════════════
    # 포트 8443: 관리자 전용 (모든 LiteLLM 기능)
    # 지정된 IP에서만 접근 가능
    # ══════════════════════════════════════════════
    server {
        listen 8443;
        server_name _;

        # IP 제한 — .env의 ADMIN_ALLOW_IP 대신 직접 지정
        # 아래 IP 대역을 관리자 네트워크에 맞게 수정할 것
        allow 10.0.0.0/8;
        allow 172.16.0.0/12;
        allow 192.168.0.0/16;
        allow 127.0.0.1;
        deny all;

        location / {
            proxy_pass http://litellm_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_read_timeout 300s;
            proxy_buffering off;
        }
    }
}
NGINX
```

> **⚠️ Admin IP 대역 수정 필수**
>
> 위 설정의 `allow` 지시문에 실제 관리자가 접근할 IP 대역을 지정해야 한다. 기본값은 사설 네트워크 전체 대역이므로 프로덕션 환경에서는 반드시 관리자 PC의 IP 또는 관리 네트워크 대역으로 좁혀야 한다.

## 2.5. Docker Compose 파일

**docker-compose.yml**

```yaml
cat > docker-compose.yml << 'YAML'
x-common: &common
  restart: unless-stopped

services:
  # ─── OpenBao (Secret Manager) ───
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
      # OpenBao 연결 (Vault 호환)
      HCP_VAULT_ADDR: "http://openbao:8200"
      HCP_VAULT_TOKEN: "${OPENBAO_ROOT_TOKEN}"
      HCP_VAULT_MOUNT_NAME: "secret"
      HCP_VAULT_PATH_PREFIX: "litellm"
      HCP_VAULT_REFRESH_INTERVAL: "3600"
    volumes:
      - ./litellm/config.yaml:/app/config.yaml
    command: --config /app/config.yaml --port 4000 --detailed_debug
    networks:
      - llm-net

  # ─── Nginx (리버스 프록시 / 접근 제한) ───
  nginx:
    <<: *common
    image: nginx:alpine
    container_name: llm-nginx
    depends_on:
      - litellm
    ports:
      - "80:80"       # 일반 사용자용 (Codex CLI)
      - "8443:8443"   # 관리자 전용 (Admin UI)
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    networks:
      - llm-net

networks:
  llm-net:
    driver: bridge
YAML
```

> **📝 포트 노출 범위**
>
> LiteLLM(4000), OpenBao(8200), PostgreSQL(5432) 포트는 호스트에 직접 노출하지 않는다. 모든 외부 접근은 Nginx(80, 8443)를 통해서만 이루어진다. 방화벽에서 80, 8443 이외의 포트는 반드시 차단할 것.

---

# 3. Phase 2 — OpenBao 초기화 및 사용자별 API Key 저장

## 3.1. OpenBao 기동 및 초기화

**OpenBao 기동 → 초기화 → Unseal**

```bash
# 1. OpenBao만 먼저 기동
docker compose up -d openbao
sleep 3

# 2. 초기화 (Shamir key-shares=5, threshold=3)
docker exec openbao bao operator init \
  -key-shares=5 -key-threshold=3 \
  -format=json > openbao/init-keys.json
chmod 600 openbao/init-keys.json

# 3. Unseal (3개 키 입력)
for i in 0 1 2; do
  KEY=$(jq -r ".unseal_keys_b64[$i]" openbao/init-keys.json)
  docker exec openbao bao operator unseal "$KEY"
  sleep 1
done

# 4. 상태 확인 — Sealed: false 확인
docker exec openbao bao status

# 5. Root Token 추출 및 .env에 기록
ROOT_TOKEN=$(jq -r '.root_token' openbao/init-keys.json)
sed -i "s/^OPENBAO_ROOT_TOKEN=.*/OPENBAO_ROOT_TOKEN=$ROOT_TOKEN/" .env
echo "Root Token: $ROOT_TOKEN"
```

> **⚠️ init-keys.json 보안**
>
> `init-keys.json`에는 Unseal Key 5개와 Root Token이 포함되어 있다. 오프라인 안전 장소에 백업 후 서버에서 삭제할 것.

## 3.2. KV 시크릿 엔진 활성화

```bash
ROOT_TOKEN=$(jq -r '.root_token' openbao/init-keys.json)

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao secrets enable -path=secret -version=2 kv
```

## 3.3. 사용자별 OpenAI API Key 저장 (10명)

각 사용자의 OpenAI API Key를 OpenBao에 개별 경로로 저장한다. LiteLLM은 `secret/data/litellm/{KEY_NAME}` 경로에서 `key` 필드 값을 읽는다.

**10명의 OpenAI API Key 저장**

```bash
ROOT_TOKEN=$(jq -r '.root_token' openbao/init-keys.json)

# ── 사용자별 OpenAI API Key 저장 ──
# 실제 환경에서는 각 사용자의 고유한 OpenAI API Key를 입력한다.

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER01_OPENAI_KEY key="sk-proj-user01-real-openai-key"

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER02_OPENAI_KEY key="sk-proj-user02-real-openai-key"

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER03_OPENAI_KEY key="sk-proj-user03-real-openai-key"

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER04_OPENAI_KEY key="sk-proj-user04-real-openai-key"

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER05_OPENAI_KEY key="sk-proj-user05-real-openai-key"

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER06_OPENAI_KEY key="sk-proj-user06-real-openai-key"

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER07_OPENAI_KEY key="sk-proj-user07-real-openai-key"

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER08_OPENAI_KEY key="sk-proj-user08-real-openai-key"

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER09_OPENAI_KEY key="sk-proj-user09-real-openai-key"

docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER10_OPENAI_KEY key="sk-proj-user10-real-openai-key"

# ── 저장 확인 ──
docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv get secret/litellm/USER01_OPENAI_KEY
```

> **ℹ️ OpenBao 시크릿 경로 매핑 표**
>
> | 사용자 | OpenBao 경로 | LiteLLM config 참조명 |
> |-------|-------------|---------------------|
> | User 01 | `secret/litellm/USER01_OPENAI_KEY` | `os.environ/USER01_OPENAI_KEY` |
> | User 02 | `secret/litellm/USER02_OPENAI_KEY` | `os.environ/USER02_OPENAI_KEY` |
> | User 03 | `secret/litellm/USER03_OPENAI_KEY` | `os.environ/USER03_OPENAI_KEY` |
> | User 04 | `secret/litellm/USER04_OPENAI_KEY` | `os.environ/USER04_OPENAI_KEY` |
> | User 05 | `secret/litellm/USER05_OPENAI_KEY` | `os.environ/USER05_OPENAI_KEY` |
> | User 06 | `secret/litellm/USER06_OPENAI_KEY` | `os.environ/USER06_OPENAI_KEY` |
> | User 07 | `secret/litellm/USER07_OPENAI_KEY` | `os.environ/USER07_OPENAI_KEY` |
> | User 08 | `secret/litellm/USER08_OPENAI_KEY` | `os.environ/USER08_OPENAI_KEY` |
> | User 09 | `secret/litellm/USER09_OPENAI_KEY` | `os.environ/USER09_OPENAI_KEY` |
> | User 10 | `secret/litellm/USER10_OPENAI_KEY` | `os.environ/USER10_OPENAI_KEY` |

---

# 4. Phase 3 — LiteLLM Proxy 구성 (사용자-모델 매핑)

## 4.1. 핵심 설계: 사용자별 전용 모델 항목

LiteLLM에서 Virtual Key를 특정 OpenAI Key에 1:1로 매핑하려면, **사용자별로 고유한 model_name을 정의**하고 각 항목에 해당 사용자의 OpenAI Key를 지정해야 한다. Virtual Key 발급 시 `models` 파라미터로 해당 사용자의 모델만 접근 가능하도록 제한한다.

**모델 이름 규칙**

```text
형식: {사용자ID}-{모델명}
예시: user01-gpt-4o, user01-o3-mini, user02-gpt-4o, user02-o3-mini ...

- LiteLLM config에서 model_name으로 사용
- Codex CLI에서 --model 플래그 또는 config.toml의 model 항목에 지정
- Virtual Key 발급 시 models 배열에 포함하여 접근 제한
```

## 4.2. LiteLLM 설정 파일 (config.yaml)

**litellm/config.yaml — 사용자별 모델 매핑**

```yaml
cat > litellm/config.yaml << 'YAML'
# ══════════════════════════════════════════════════════════
# LiteLLM Proxy — 사용자별 OpenAI Key 매핑 설정
# ══════════════════════════════════════════════════════════
#
# 설계 원칙:
#   - 각 사용자(user01~user10)마다 전용 model_name 항목을 정의
#   - 각 항목은 OpenBao에 저장된 해당 사용자의 OpenAI API Key를 참조
#   - Virtual Key 발급 시 models 제한으로 다른 사용자의 모델 접근 차단
#

model_list:

  # ══════════════════════════
  # User 01
  # ══════════════════════════
  - model_name: user01-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER01_OPENAI_KEY"

  - model_name: user01-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER01_OPENAI_KEY"

  # ══════════════════════════
  # User 02
  # ══════════════════════════
  - model_name: user02-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER02_OPENAI_KEY"

  - model_name: user02-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER02_OPENAI_KEY"

  # ══════════════════════════
  # User 03
  # ══════════════════════════
  - model_name: user03-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER03_OPENAI_KEY"

  - model_name: user03-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER03_OPENAI_KEY"

  # ══════════════════════════
  # User 04
  # ══════════════════════════
  - model_name: user04-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER04_OPENAI_KEY"

  - model_name: user04-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER04_OPENAI_KEY"

  # ══════════════════════════
  # User 05
  # ══════════════════════════
  - model_name: user05-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER05_OPENAI_KEY"

  - model_name: user05-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER05_OPENAI_KEY"

  # ══════════════════════════
  # User 06
  # ══════════════════════════
  - model_name: user06-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER06_OPENAI_KEY"

  - model_name: user06-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER06_OPENAI_KEY"

  # ══════════════════════════
  # User 07
  # ══════════════════════════
  - model_name: user07-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER07_OPENAI_KEY"

  - model_name: user07-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER07_OPENAI_KEY"

  # ══════════════════════════
  # User 08
  # ══════════════════════════
  - model_name: user08-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER08_OPENAI_KEY"

  - model_name: user08-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER08_OPENAI_KEY"

  # ══════════════════════════
  # User 09
  # ══════════════════════════
  - model_name: user09-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER09_OPENAI_KEY"

  - model_name: user09-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER09_OPENAI_KEY"

  # ══════════════════════════
  # User 10
  # ══════════════════════════
  - model_name: user10-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER10_OPENAI_KEY"

  - model_name: user10-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER10_OPENAI_KEY"


# ══════════════════════════════════════════════════════════
# General Settings
# ══════════════════════════════════════════════════════════
general_settings:
  master_key: "os.environ/LITELLM_MASTER_KEY"
  database_url: "os.environ/DATABASE_URL"

  # OpenBao (Vault 호환) 연동
  key_management_system: "hashicorp_vault"
  key_management_settings:
    store_virtual_keys: true
    prefix_for_stored_virtual_keys: "litellm/vkeys/"
    access_mode: "read_and_write"

  # ── 입출력 로그 설정 ──
  store_model_in_db: true                       # 모델 정보를 DB에 저장
  store_prompts_in_spend_logs: true              # 요청/응답 내용을 spend logs에 저장
  maximum_spend_logs_retention_period: "90d"     # 로그 보관 기간 (90일)
  maximum_spend_logs_retention_interval: "1d"    # 로그 정리 실행 주기 (1일)

# ══════════════════════════════════════════════════════════
# Router / LiteLLM Settings
# ══════════════════════════════════════════════════════════
router_settings:
  num_retries: 2
  timeout: 120

litellm_settings:
  drop_params: true
  set_verbose: false
YAML
```

> **💡 모델 추가 방법**
>
> 사용자에게 추가 모델(예: `gpt-4o-mini`, `o4-mini`)을 제공하려면 동일한 패턴으로 항목을 추가한다. 예를 들어 User 01에게 `gpt-4o-mini`를 추가하려면:
>
> ```yaml
>   - model_name: user01-gpt-4o-mini
>     litellm_params:
>       model: openai/gpt-4o-mini
>       api_key: "os.environ/USER01_OPENAI_KEY"
> ```
>
> 그리고 해당 사용자의 Virtual Key를 `/key/update` API로 업데이트하여 `models` 배열에 새 모델을 추가한다.

> **ℹ️ 입출력 로그 설정 해설**
>
> | 설정 항목 | 설명 |
> |----------|------|
> | `store_model_in_db: true` | 모델 정보를 DB에 저장. Admin UI에서 모델별 조회 시 필요. |
> | `store_prompts_in_spend_logs: true` | 사용자의 요청(prompt)과 LLM 응답(response) 내용을 PostgreSQL의 `LiteLLM_SpendLogs` 테이블에 저장. 관리자가 Admin UI → Logs 탭에서 전체 입출력 이력을 열람할 수 있다. |
> | `maximum_spend_logs_retention_period: "90d"` | 로그 보관 기간. 90일이 지난 로그는 자동 삭제된다. 필요에 따라 `"30d"`, `"180d"` 등으로 조정. |
> | `maximum_spend_logs_retention_interval: "1d"` | 로그 정리(cleanup) 작업 실행 주기. 매일 1회 실행. |
>
> 이 설정이 활성화된 후 발생한 요청부터 입출력 내용이 기록된다. 설정 이전의 요청에 대해서는 입출력 내용이 저장되지 않는다.

> **⚠️ 입출력 로그 보안 주의**
>
> `store_prompts_in_spend_logs: true` 설정 시 사용자의 모든 요청/응답 텍스트가 PostgreSQL에 평문으로 저장된다. 민감한 정보가 포함될 수 있으므로 아래 사항을 반드시 확인한다.
>
> - PostgreSQL 데이터 디렉토리의 파일 시스템 권한을 제한한다.
> - DB 접속 비밀번호를 강력하게 설정한다.
> - 로그 보관 기간(`maximum_spend_logs_retention_period`)을 조직의 보안 정책에 맞게 설정한다.
> - Nginx 포트 80에서 `/spend/*` 경로를 차단하여 일반 사용자의 로그 조회를 원천 차단한다.

---

# 5. Phase 4 — 시스템 기동 및 검증

## 5.1. 전체 서비스 시작

```bash
cd ~/llm-gateway

# 전체 서비스 기동
docker compose up -d

# LiteLLM 로그 확인 (OpenBao 연결 및 모델 로드 확인)
docker compose logs -f litellm
```

## 5.2. 기동 검증

**헬스체크 및 모델 목록 확인**

```bash
# 일반 사용자 포트(80)로 헬스체크
curl http://localhost/health

# 관리자 포트(8443)로 모델 목록 확인
curl http://localhost:8443/v1/models \
  -H "Authorization: Bearer $(grep LITELLM_MASTER_KEY .env | cut -d= -f2)" \
  | jq '.data[].id'

# Admin UI 접근 차단 확인 — 포트 80에서 403 반환되어야 정상
curl -s http://localhost/ui | jq .
```

---

# 6. Phase 5 — 사용자별 Virtual Key 발급

## 6.1. Virtual Key 발급 (관리자 실행)

아래 명령은 **관리자 포트(8443)**에서 Master Key를 사용하여 실행한다. 각 사용자에게 자신의 모델만 접근 가능한 Virtual Key를 발급한다.

**10명 Virtual Key 일괄 발급 스크립트**

```bash
#!/bin/bash
# ──────────────────────────────────────────────
# generate_virtual_keys.sh
# 사용자별 Virtual Key 발급 스크립트
# 관리자 PC에서 실행
# ──────────────────────────────────────────────

LITELLM_ADMIN_URL="http://<서버IP>:8443"
MASTER_KEY="sk-master-change-me-to-random-string"  # .env의 LITELLM_MASTER_KEY 값

# 사용자 목록: ID, 이름, 할당 모델
declare -A USERS=(
  ["user01"]="홍길동"
  ["user02"]="김철수"
  ["user03"]="이영희"
  ["user04"]="박민수"
  ["user05"]="최지은"
  ["user06"]="정서연"
  ["user07"]="강도현"
  ["user08"]="윤하은"
  ["user09"]="장현우"
  ["user10"]="한소율"
)

echo "═══════════════════════════════════════════"
echo " Virtual Key 발급 결과"
echo "═══════════════════════════════════════════"

for USER_ID in $(echo "${!USERS[@]}" | tr ' ' '\n' | sort); do
  USER_NAME="${USERS[$USER_ID]}"

  RESULT=$(curl -s -X POST "${LITELLM_ADMIN_URL}/key/generate" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"models\": [\"${USER_ID}-gpt-4o\", \"${USER_ID}-o3-mini\"],
      \"metadata\": {
        \"user\": \"${USER_NAME}\",
        \"user_id\": \"${USER_ID}\",
        \"purpose\": \"codex-cli\"
      },
      \"key_alias\": \"${USER_ID}-codex-key\",
      \"max_budget\": 50.0,
      \"budget_duration\": \"30d\"
    }")

  VIRTUAL_KEY=$(echo "$RESULT" | jq -r '.key')
  echo ""
  echo "  ${USER_ID} (${USER_NAME})"
  echo "  ├─ Virtual Key: ${VIRTUAL_KEY}"
  echo "  ├─ 모델: ${USER_ID}-gpt-4o, ${USER_ID}-o3-mini"
  echo "  └─ 월 예산: $50.00"
done

echo ""
echo "═══════════════════════════════════════════"
echo " 발급 완료. 각 사용자에게 Virtual Key를 전달하세요."
echo "═══════════════════════════════════════════"
```

## 6.2. 개별 사용자 Virtual Key 발급 (단건)

**User 01 Virtual Key 발급 예시**

```bash
curl -X POST http://<서버IP>:8443/key/generate \
  -H "Authorization: Bearer sk-master-change-me-to-random-string" \
  -H "Content-Type: application/json" \
  -d '{
    "models": ["user01-gpt-4o", "user01-o3-mini"],
    "metadata": {
      "user": "홍길동",
      "user_id": "user01",
      "purpose": "codex-cli"
    },
    "key_alias": "user01-codex-key",
    "max_budget": 50.0,
    "budget_duration": "30d"
  }' | jq

# 응답에서 "key" 필드 값이 해당 사용자의 Virtual Key이다.
# 예: "key": "sk-vk-abcdef123456..."
```

> **ℹ️ Virtual Key 발급 파라미터 설명**
>
> | 파라미터 | 설명 | 예시 |
> |---------|------|------|
> | `models` | 이 Key로 접근 가능한 모델 목록 (타 사용자의 모델은 포함하지 않음) | `["user01-gpt-4o", "user01-o3-mini"]` |
> | `max_budget` | 예산 한도 (USD). 초과 시 요청 거부 | `50.0` |
> | `budget_duration` | 예산 리셋 주기 | `"30d"` (30일) |
> | `key_alias` | Key의 식별용 별칭 | `"user01-codex-key"` |
> | `metadata` | 사용자 정보 등 추가 메타데이터 | `{"user": "홍길동", "purpose": "codex-cli"}` |

---

# 7. Phase 6 — Codex CLI 사용자 설정 가이드

> **사용자에게 전달할 정보**
>
> 각 사용자에게 아래 3가지 정보를 전달한다.
>
> 1. **Virtual Key** — 예: `sk-vk-abcdef123456...`
> 2. **LiteLLM Proxy URL** — 예: `http://<서버IP>` (포트 80)
> 3. **모델 이름** — 예: `user01-gpt-4o` 또는 `user01-o3-mini`

## 7.1. Codex CLI 설치

**Codex CLI 설치 (Node.js 필요)**

```bash
# npm으로 설치
npm install -g @openai/codex

# 설치 확인
codex --version
```

## 7.2. Codex CLI 설정 (config.toml)

사용자 PC에서 `~/.codex/config.toml` 파일을 아래와 같이 설정한다.

**config.toml 설정 (사용자 PC에서 실행)**

```bash
mkdir -p ~/.codex

cat > ~/.codex/config.toml << 'TOML'
# ──────────────────────────────────────────────
# Codex CLI 설정 — LiteLLM Proxy 연결
# ──────────────────────────────────────────────

# LiteLLM Proxy의 base URL (포트 80)
openai_base_url = "http://<서버IP>/v1"

# 사용할 모델 (관리자에게 전달받은 모델 이름)
model = "user01-gpt-4o"

# 승인 모드 설정
approval_mode = "suggest"
TOML
```

## 7.3. 환경변수 설정

**환경변수 설정 (사용자 PC에서 실행)**

```bash
# .bashrc 또는 .zshrc에 추가
export OPENAI_API_KEY="sk-vk-abcdef123456..."   # 관리자에게 전달받은 Virtual Key

# 적용
source ~/.bashrc  # 또는 source ~/.zshrc
```

## 7.4. Codex CLI 실행 및 테스트

**Codex CLI 실행**

```bash
# 대화형 세션 시작
codex

# 특정 모델 지정하여 시작
codex --model user01-gpt-4o

# 일회성 명령 실행
codex exec "이 프로젝트의 README.md를 작성해줘" --model user01-gpt-4o
```

> **📝 모델 변경**
>
> Codex CLI 세션 중 `/model` 명령으로 모델을 전환할 수 있다. 단, 자신에게 할당된 모델만 사용 가능하다.
>
> ```text
> # Codex 세션 내에서
> /model user01-o3-mini
> ```

---

# 8. 사용량 모니터링

## 8.1. 사용자 본인의 사용량 조회

일반 사용자는 Admin UI에 접근할 수 없으므로, `/key/info` API 엔드포인트로 자신의 사용량을 조회한다. 이 엔드포인트는 Nginx 설정에서 일반 사용자 포트(80)에도 허용되어 있다.

**사용량 조회 명령 (사용자 PC에서 실행)**

```bash
# 자신의 Virtual Key로 사용량 조회
curl -s "http://<서버IP>/key/info" \
  -H "Authorization: Bearer sk-vk-abcdef123456..." \
  | jq '{
    key_alias: .info.key_alias,
    spend: .info.spend,
    max_budget: .info.max_budget,
    budget_duration: .info.budget_duration,
    models: .info.models,
    created_at: .info.created_at,
    expires_at: .info.expires
  }'
```

출력 예시:

**사용량 조회 응답 예시**

```json
{
  "key_alias": "user01-codex-key",
  "spend": 12.35,
  "max_budget": 50.0,
  "budget_duration": "30d",
  "models": ["user01-gpt-4o", "user01-o3-mini"],
  "created_at": "2026-05-06T09:00:00.000Z",
  "expires_at": null
}
```

## 8.2. 사용량 조회 셸 스크립트 (사용자 배포용)

편의를 위해 아래 스크립트를 사용자에게 배포할 수 있다.

**check-usage.sh — 사용자 배포용 스크립트**

```bash
#!/bin/bash
# ──────────────────────────────────────────────
# LLM 사용량 조회 스크립트
# 환경변수 OPENAI_API_KEY에 Virtual Key가 설정되어 있어야 합니다.
# ──────────────────────────────────────────────

SERVER="http://<서버IP>"
VKEY="${OPENAI_API_KEY}"

if [ -z "$VKEY" ]; then
  echo "오류: OPENAI_API_KEY 환경변수가 설정되지 않았습니다."
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " LLM 사용량 리포트"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

curl -s "${SERVER}/key/info" \
  -H "Authorization: Bearer ${VKEY}" \
  | jq -r '
    "  사용자:     " + (.info.key_alias // "N/A"),
    "  사용 금액:  $" + (.info.spend | tostring),
    "  월 한도:    $" + (.info.max_budget | tostring),
    "  잔여 한도:  $" + ((.info.max_budget - .info.spend) | tostring),
    "  사용 가능 모델: " + (.info.models | join(", "))
  '

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

## 8.3. 관리자: 전체 사용자 사용량 조회

**관리자 — 전체 Key 사용량 조회**

```bash
# 관리자 포트(8443)에서 Master Key로 조회
curl -s "http://<서버IP>:8443/key/list" \
  -H "Authorization: Bearer sk-master-change-me-to-random-string" \
  | jq '.keys[] | {alias: .key_alias, spend: .spend, max_budget: .max_budget, models: .models}'
```

또는 관리자는 `http://<서버IP>:8443/ui`로 LiteLLM Admin Dashboard에 접속하여 GUI로 전체 사용량을 모니터링할 수 있다.

---

# 9. 입출력 로그 관리 (관리자 전용)

> **로그 접근 권한 구분**
>
> | 역할 | 사용량 조회 (/key/info) | 입출력 로그 조회 | 접근 경로 |
> |------|----------------------|-----------------|----------|
> | **관리자** | ✓ 전체 사용자 | ✓ 전체 사용자의 요청/응답 열람 가능 | 포트 8443 — Admin UI Logs 탭 또는 `/spend/logs` API |
> | **일반 사용자** | ✓ 본인만 (비용/토큰 수만) | ✗ 차단 — 요청/응답 내용 열람 불가 | 포트 80 — `/spend/*` 경로 403 차단 |

## 10.1. Admin UI에서 로그 모니터링

관리자는 `http://<서버IP>:8443/ui`에 접속하여 **Logs** 탭에서 전체 사용자의 입출력 이력을 열람할 수 있다.

**Admin UI 로그 조회 경로**

```text
1. 브라우저에서 http://<서버IP>:8443/ui 접속
2. Master Key로 로그인
3. 좌측 메뉴에서 "Logs" 클릭
4. 로그 목록에서 특정 요청 클릭 → 상세 보기
   - Request: 사용자가 보낸 메시지 (prompt) 전문
   - Response: LLM이 반환한 응답 전문
   - 메타데이터: 사용 모델, 토큰 수, 비용, 소요시간, Key alias 등
```

> **💡 Admin UI에서 로그 저장 설정 변경**
>
> Admin UI → Logs → Settings(톱니바퀴 아이콘)에서 아래 설정을 런타임에 변경할 수 있다. config.yaml을 수정하거나 프록시를 재시작할 필요가 없다.
>
> - **Store Prompts in Spend Logs** — 입출력 내용 저장 On/Off (디버깅 시에만 켜고 평소에는 끌 수 있음)
> - **Retention Period** — 로그 보관 기간 변경
>
> UI에서 변경한 값은 config.yaml 설정보다 우선 적용된다.

## 10.2. API로 로그 조회 (관리자)

관리자 포트(8443)에서 `/spend/logs` API를 사용하여 프로그래밍 방식으로 로그를 조회할 수 있다.

**특정 Virtual Key의 입출력 로그 조회**

```bash
# 특정 사용자(Key)의 최근 로그 조회
curl -s "http://<서버IP>:8443/spend/logs" \
  -H "Authorization: Bearer sk-master-change-me-to-random-string" \
  -H "Content-Type: application/json" \
  -d '{
    "api_key": "sk-vk-user01-virtual-key",
    "start_date": "2026-05-01",
    "end_date": "2026-05-06"
  }' | jq '.[0] | {
    request_id,
    api_key: .api_key,
    model: .model,
    messages: .messages,
    response: .response,
    startTime,
    endTime,
    spend: .spend,
    total_tokens: .total_tokens
  }'
```

**전체 사용자의 최근 로그 조회**

```bash
# 전체 로그 조회 (최근 N건)
curl -s "http://<서버IP>:8443/spend/logs" \
  -H "Authorization: Bearer sk-master-change-me-to-random-string" \
  -H "Content-Type: application/json" \
  -d '{
    "start_date": "2026-05-01",
    "end_date": "2026-05-06"
  }' | jq '.[] | {
    key_alias: .metadata.key_alias,
    user: .metadata.user,
    model,
    prompt: (.messages | tostring | .[0:100]),
    response: (.response | tostring | .[0:100]),
    spend,
    startTime
  }'
```

## 10.3. 일반 사용자의 로그 접근 차단 확인

**일반 사용자 포트(80)에서 로그 차단 테스트**

```bash
# 포트 80에서 /spend/logs 접근 — 403 반환되어야 정상
curl -s http://<서버IP>/spend/logs \
  -H "Authorization: Bearer sk-vk-user01-virtual-key" \
  | jq .

# 예상 응답:
# {"error": "Access denied. Log history requires admin access."}

# 포트 80에서 /global/spend/logs 접근 — 403 반환되어야 정상
curl -s http://<서버IP>/global/spend/logs \
  -H "Authorization: Bearer sk-vk-user01-virtual-key" \
  | jq .
```

> **📝 일반 사용자가 볼 수 있는 정보와 볼 수 없는 정보**
>
> | 정보 | 일반 사용자 | 관리자 |
> |------|-----------|-------|
> | 자신의 총 사용 금액 (spend) | ✓ `/key/info` | ✓ |
> | 자신의 예산 한도 / 잔여 예산 | ✓ `/key/info` | ✓ |
> | 자신의 허용 모델 목록 | ✓ `/key/info` | ✓ |
> | 자신의 요청/응답 텍스트 (입출력 로그) | ✗ 차단 | ✓ Admin UI Logs 또는 `/spend/logs` API |
> | 타 사용자의 모든 정보 | ✗ 차단 | ✓ |

---

# 10. 운영 가이드

## 10.1. 사용자의 OpenAI API Key 로테이션

**User 01의 OpenAI Key 교체**

```bash
ROOT_TOKEN=$(jq -r '.root_token' openbao/init-keys.json)

# OpenBao에서 새 키로 업데이트
docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER01_OPENAI_KEY \
  key="sk-proj-user01-new-rotated-key"

# LiteLLM 재시작 (즉시 반영)
docker compose restart litellm

# 사용자의 Virtual Key는 변경 불필요 — 동일한 Virtual Key로 계속 사용 가능
```

> **💡 사용자에게 미치는 영향**
>
> OpenAI API Key를 교체해도 사용자의 Virtual Key는 변경되지 않는다. 사용자는 아무런 조치 없이 기존 Virtual Key로 계속 사용할 수 있다. 이것이 이 아키텍처의 핵심 장점이다.

## 10.2. 신규 사용자 추가 절차

**User 11 추가 예시**

```bash
# 1. OpenBao에 새 사용자의 OpenAI Key 저장
docker exec -e BAO_TOKEN="$ROOT_TOKEN" openbao \
  bao kv put secret/litellm/USER11_OPENAI_KEY \
  key="sk-proj-user11-openai-key"

# 2. litellm/config.yaml에 모델 항목 추가
cat >> litellm/config.yaml << 'YAML'

  # User 11
  - model_name: user11-gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: "os.environ/USER11_OPENAI_KEY"
  - model_name: user11-o3-mini
    litellm_params:
      model: openai/o3-mini
      api_key: "os.environ/USER11_OPENAI_KEY"
YAML

# 3. LiteLLM 재시작
docker compose restart litellm

# 4. Virtual Key 발급
curl -X POST http://<서버IP>:8443/key/generate \
  -H "Authorization: Bearer sk-master-change-me-to-random-string" \
  -H "Content-Type: application/json" \
  -d '{
    "models": ["user11-gpt-4o", "user11-o3-mini"],
    "metadata": {"user": "신규사용자", "user_id": "user11"},
    "key_alias": "user11-codex-key",
    "max_budget": 50.0,
    "budget_duration": "30d"
  }'
```

## 10.3. 사용자 비활성화

**Virtual Key 차단**

```bash
# 사용자의 Virtual Key 차단
curl -X POST http://<서버IP>:8443/key/block \
  -H "Authorization: Bearer sk-master-change-me-to-random-string" \
  -H "Content-Type: application/json" \
  -d '{"key": "sk-vk-차단할-virtual-key"}'

# 차단 해제
curl -X POST http://<서버IP>:8443/key/unblock \
  -H "Authorization: Bearer sk-master-change-me-to-random-string" \
  -H "Content-Type: application/json" \
  -d '{"key": "sk-vk-해제할-virtual-key"}'
```

## 10.4. OpenBao 재시작 시 Unseal

**unseal.sh**

```bash
cat > openbao/unseal.sh << 'BASH'
#!/bin/bash
export BAO_ADDR="http://127.0.0.1:8200"
KEYS_FILE="/path/to/secure/init-keys.json"

for i in 0 1 2; do
  KEY=$(jq -r ".unseal_keys_b64[$i]" "$KEYS_FILE")
  docker exec openbao bao operator unseal "$KEY"
  sleep 1
done
echo "[$(date)] OpenBao unsealed"
BASH
chmod 700 openbao/unseal.sh
```

---

# 11. 보안 체크리스트

> **프로덕션 배포 전 필수 확인**
>
> | 점검 항목 | 상태 | 비고 |
> |----------|------|------|
> | `init-keys.json` 오프라인 백업 및 서버 삭제 | ☐ | 분실 시 OpenBao 복구 불가 |
> | LiteLLM Master Key 강력한 랜덤 문자열로 변경 | ☐ | `openssl rand -hex 32` |
> | PostgreSQL 비밀번호 강력한 문자열로 변경 | ☐ | 기본값 사용 금지 |
> | `.env` 파일 권한 `chmod 600` | ☐ | 소유자만 읽기 가능 |
> | Nginx Admin 포트(8443) IP 제한 설정 | ☐ | 관리자 IP만 허용 |
> | 포트 80에서 `/ui` 접근 시 403 반환 확인 | ☐ | `curl http://서버/ui` |
> | 포트 80에서 `/key/generate` 접근 시 403 반환 확인 | ☐ | `curl -X POST http://서버/key/generate` |
> | 포트 80에서 `/spend/logs` 접근 시 403 반환 확인 | ☐ | `curl http://서버/spend/logs` → 일반 사용자 로그 열람 차단 |
> | `store_prompts_in_spend_logs: true` 설정 확인 | ☐ | Admin UI → Logs에서 요청/응답 내용 표시되는지 확인 |
> | 로그 보관 기간 정책 적정성 검토 | ☐ | `maximum_spend_logs_retention_period` 값이 조직 보안 정책에 부합하는지 |
> | 방화벽에서 4000, 5432, 8200 포트 외부 차단 | ☐ | Docker 내부 통신만 허용 |
> | 각 사용자 Virtual Key로 타 사용자 모델 접근 불가 확인 | ☐ | User01 키로 `user02-gpt-4o` 호출 시 거부 |
> | OpenBao 감사 로그 활성화 | ☐ | `bao audit enable file file_path=/openbao/logs/audit.log` |
> | 프로덕션에서는 Nginx에 TLS(HTTPS) 적용 | ☐ | Let's Encrypt 또는 사내 인증서 |

---

# 12. 트러블슈팅

<details>
<summary><b>Codex CLI에서 "model not found" 오류</b></summary>

`config.toml`의 `model` 값이 LiteLLM config의 `model_name`과 정확히 일치하는지 확인한다. 대소문자 및 하이픈 위치가 정확해야 한다.

```bash
# 사용 가능한 모델 목록 확인
curl -s http://<서버IP>/v1/models \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  | jq '.data[].id'
```

</details>

<details>
<summary><b>Codex CLI에서 "This model is not available" 오류</b></summary>

Virtual Key에 할당된 모델이 아닌 다른 모델에 접근하려 할 때 발생한다. 자신에게 할당된 모델만 사용해야 한다.

```bash
# 자신의 Key에 할당된 모델 확인
curl -s http://<서버IP>/key/info \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  | jq '.info.models'
```

</details>

<details>
<summary><b>Codex CLI 스트리밍이 끊기거나 타임아웃 발생</b></summary>

Nginx의 `proxy_read_timeout`, `proxy_send_timeout` 값을 확인한다. Codex CLI는 장시간 스트리밍 연결을 유지하므로 타임아웃을 300초 이상으로 설정해야 한다. 또한 `proxy_buffering off`가 설정되어 있는지 확인한다.

</details>

<details>
<summary><b>LiteLLM이 OpenBao에서 Key를 읽지 못할 때</b></summary>

1. OpenBao가 Unsealed 상태인지 확인: `docker exec openbao bao status`
2. `HCP_VAULT_ADDR`가 `http://openbao:8200`인지 확인 (Docker 네트워크 내부 주소)
3. 시크릿 직접 조회: `bao kv get secret/litellm/USER01_OPENAI_KEY`
4. LiteLLM 로그에서 vault 관련 에러 확인: `docker compose logs litellm | grep -i vault`

</details>

<details>
<summary><b>Admin UI에 일반 포트(80)로 접근되는 경우</b></summary>

Nginx 설정 파일에서 `/ui` location 블록이 정확히 정의되어 있는지 확인한다. Nginx를 재시작하고 테스트한다.

```bash
docker compose restart nginx

# 테스트 — 403 응답이어야 정상
curl -s -o /dev/null -w "%{http_code}" http://localhost/ui
```

</details>

---

# 13. 접속 정보 요약

| 서비스 | URL | 대상 | 인증 |
|-------|-----|------|------|
| LLM API (Codex CLI) | `http://<서버IP>/v1` | 일반 사용자 | Virtual Key |
| 사용량 조회 | `http://<서버IP>/key/info` | 일반 사용자 | Virtual Key |
| Admin UI | `http://<서버IP>:8443/ui` | 관리자만 | Master Key + IP 제한 |
| Key 관리 API | `http://<서버IP>:8443/key/*` | 관리자만 | Master Key + IP 제한 |
| OpenBao UI | 호스트에 노출하지 않음 (내부만) | 관리자만 | Root Token |

---

# 14. 참고자료

| 항목 | URL |
|------|-----|
| OpenBao 공식 문서 | https://openbao.org/docs/ |
| LiteLLM Virtual Keys | https://docs.litellm.ai/docs/proxy/virtual_keys |
| LiteLLM Hashicorp Vault 연동 | https://docs.litellm.ai/docs/secret_managers/hashicorp_vault |
| LiteLLM Model Access 제한 | https://docs.litellm.ai/docs/proxy/model_access |
| Codex CLI 설정 기본 | https://developers.openai.com/codex/config-basic |
| Codex CLI 고급 설정 | https://developers.openai.com/codex/config-advanced |
| Codex CLI 설정 레퍼런스 | https://developers.openai.com/codex/config-reference |
| Codex CLI 사용 가능 모델 | https://developers.openai.com/codex/models |
