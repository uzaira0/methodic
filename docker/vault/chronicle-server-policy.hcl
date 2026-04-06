# Chronicle Server Vault Policy
# Grants least-privilege access to application secrets.
# HIPAA §164.312(a)(1) — Access control for electronic PHI systems.
#
# Path structure: secret/data/chronicle/{category}
#   database  — PostgreSQL credentials
#   jwt       — JWT signing key
#   smtp      — Email service credentials
#   hazelcast — Cluster authentication passwords
#   mobile    — Mobile app signing secret and API key
#   twilio    — SMS provider credentials
#   crowdsec  — WAF bouncer API key
#   grafana   — Monitoring dashboard admin password

# Read application secrets (KV v2 data path)
path "secret/data/chronicle/*" {
    capabilities = ["read"]
}

# Read secret metadata (required for versioned reads)
path "secret/metadata/chronicle/*" {
    capabilities = ["read", "list"]
}

# Deny destructive operations on secrets
path "secret/delete/chronicle/*" {
    capabilities = ["deny"]
}

path "secret/destroy/chronicle/*" {
    capabilities = ["deny"]
}

# Deny access to TDE keys (managed separately by PostgreSQL)
path "secret/data/chronicle/tde-principal-key" {
    capabilities = ["deny"]
}
