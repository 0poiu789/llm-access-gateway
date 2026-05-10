ui = true

storage "file" {
  path = "/openbao/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

# WI-4: 모든 KV read/write를 JSON 라인으로 audit log에 기록 (HMAC 토큰 accessor만)
# OpenBao declarative audit device — API enable는 deprecated.
# device-specific 설정은 options 블록에 둔다 (Vault/OpenBao 표준 형식).
audit {
  path = "file/"
  type = "file"
  options = {
    file_path     = "/openbao/logs/audit.log"
    log_raw       = "false"
    hmac_accessor = "true"
  }
}

api_addr          = "http://0.0.0.0:8200"
default_lease_ttl = "168h"
max_lease_ttl     = "720h"
disable_mlock     = true
