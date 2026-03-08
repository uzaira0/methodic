# Chronicle Security Infrastructure

Security hardening for the Chronicle deployment. Deploy as a Docker Compose overlay on top of the base `docker-compose.traefik.yml`.

## Components

| Component | Purpose | Image | Memory |
|-----------|---------|-------|--------|
| **Coraza WAF** | OWASP CRS web application firewall | `corazawaf/coraza-caddy` | 256MB |
| **HashiCorp Vault** | Encrypted secrets management | `hashicorp/vault:1.15` | 256MB |
| **Fail2ban** | IP banning for rate-limit/auth abuse | `crazymax/fail2ban` | 128MB |
| **Falco** | Container runtime security monitoring | `falcosecurity/falco` | 512MB |

Total additional resources: ~1.2GB RAM

## Deployment

```bash
cd /opt/chronicle/docker

# Deploy with security overlay
docker compose \
  -f docker-compose.traefik.yml \
  -f docker-compose.security.yml \
  -p chronicle up -d
```

## Post-Deployment Setup

### 1. Initialize Vault

```bash
# Initialize and unseal Vault (run once)
docker exec chronicle-vault sh /vault/scripts/init-vault.sh

# SAVE THE UNSEAL KEYS AND ROOT TOKEN SECURELY

# Seed secrets from .env
docker exec -e VAULT_TOKEN=<root_token> chronicle-vault sh -c '
  vault kv put chronicle/database \
    user=$POSTGRES_USER \
    password=$POSTGRES_PASSWORD
  vault kv put chronicle/jwt secret=$JWT_SECRET
  vault kv put chronicle/smtp \
    host=$SMTP_HOST \
    port=$SMTP_PORT \
    username=$SMTP_USERNAME \
    password=$SMTP_PASSWORD
'

# Enable audit logging
docker exec -e VAULT_TOKEN=<root_token> chronicle-vault \
  vault audit enable file file_path=/vault/logs/audit.log
```

### 2. Configure Traefik Access Logs (for Fail2ban)

Fail2ban monitors Traefik access logs. Ensure Traefik is configured to write access logs:

```yaml
# In Traefik static configuration:
accessLog:
  filePath: /var/log/traefik/access.log
  format: common
```

The `traefik_logs` volume must be shared between Traefik and Fail2ban containers.

### 3. Verify Components

```bash
# Check WAF is proxying
curl -v http://localhost:8080/prometheus/

# Check Fail2ban status
docker exec chronicle-fail2ban fail2ban-client status

# Check Falco alerts
docker logs chronicle-falco --tail 20

# Check Vault status
docker exec chronicle-vault vault status
```

## WAF Tuning

The Coraza WAF uses OWASP CRS at Paranoia Level 1 (balanced). To increase strictness:

Edit `security/coraza/Caddyfile`:
- Paranoia Level 2: More rules, some false positives on complex JSON
- Paranoia Level 3: Strict, may require rule exclusions for API endpoints
- Paranoia Level 4: Maximum, significant tuning required

## Falco Custom Rules

Chronicle-specific rules in `security/falco/chronicle-rules.yaml`:
- Shell access in application containers (WARNING)
- Unexpected outbound connections from backend (NOTICE)
- File writes to system paths (ERROR)
- Secrets file access by unexpected processes (WARNING)
- Privilege escalation attempts (CRITICAL)
- Package manager usage in running containers (ERROR)
- Crypto mining indicators (CRITICAL)

## API Schema Validation Note

The plan included Spring OpenAPI validation as the 5th component. Since Chronicle uses the Rhizome framework (not Spring Boot), `springdoc-openapi` auto-configuration is not available. Instead, use Jakarta Bean Validation annotations (`@Valid`, `@NotNull`, `@Size`, etc.) on controller method parameters and DTO fields for request validation. This is already partially implemented in the existing codebase.
