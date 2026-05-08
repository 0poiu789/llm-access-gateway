ui = true

storage "file" {
  path = "/openbao/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr          = "http://0.0.0.0:8200"
default_lease_ttl = "168h"
max_lease_ttl     = "720h"
disable_mlock     = true
