# HashiCorp Vault Configuration for Chronicle
# Self-hosted secrets management — stores DB credentials, JWT secret, SMTP passwords, API keys

# File-based storage (sufficient for single-node self-hosted deployment)
storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  # TLS disabled inside Docker network (Traefik handles external TLS)
  tls_disable = 1
}

# API address for vault CLI
api_addr = "http://0.0.0.0:8200"

# Disable memory locking (not available in unprivileged container)
disable_mlock = true

# UI disabled in production (use vault CLI instead)
ui = false

# Audit logging
# Enable after init with: vault audit enable file file_path=/vault/logs/audit.log
