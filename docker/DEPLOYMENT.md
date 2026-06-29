# Chronicle Production Deployment Guide

## Quick Start

```bash
cd docker

# 1. Configure environment
cp .env.example .env
nano .env  # Set DOMAIN, POSTGRES_PASSWORD, JWT_SECRET

# 2. Set up SSL certificates
chmod +x init-ssl.sh
./init-ssl.sh

# 3. Deploy
docker-compose -f docker-compose.prod.yml up -d
```

## Prerequisites

- Linux VM with Docker and Docker Compose installed
- Domain name pointing to your VM's IP (for Let's Encrypt)
- Ports 80 and 443 open

---

## Step 1: Configure Environment

```bash
cp .env.example .env
nano .env
```

Required settings:

| Variable | Description | Example |
|----------|-------------|---------|
| `DOMAIN` | Your domain name | `chronicle.example.com` |
| `POSTGRES_PASSWORD` | Database password | Strong random password |
| `JWT_SECRET` | Token signing secret | `openssl rand -base64 64` |
| `MOBILE_APP_KEY` | App key for mobile API auth | `openssl rand -hex 32` |
| `LETSENCRYPT_EMAIL` | Email for Let's Encrypt | `admin@example.com` |
| `PG_TDE_KEY_PROVIDER` | Encryption key provider | `file` (dev) or `vault` (prod) |

---

## Step 2: Set Up SSL Certificates

Run the initialization script:

```bash
chmod +x init-ssl.sh
./init-ssl.sh
```

Choose one of:

1. **Self-signed** - Works immediately, shows browser warnings
2. **Let's Encrypt** - Free trusted cert, requires domain pointing to server
3. **Bring your own** - Place certs in `./certs/` manually

### Manual Certificate Placement

If providing your own certificates:

```bash
mkdir -p certs
cp /path/to/your/fullchain.pem certs/fullchain.pem
cp /path/to/your/privkey.pem certs/privkey.pem
```

### Let's Encrypt Auto-Renewal

```bash
chmod +x renew-ssl.sh

# Add to crontab (daily at midnight)
crontab -e
# Add: 0 0 * * * /path/to/docker/renew-ssl.sh >> /var/log/ssl-renew.log 2>&1
```

---

## Step 3: Deploy

```bash
docker-compose -f docker-compose.prod.yml up -d
```

Verify:

```bash
docker-compose -f docker-compose.prod.yml ps
curl -k https://your-domain.com/health
```

---

## API Routes

Chronicle uses separate API routes for mobile and web clients with different security requirements.

### Route Structure

| Route | Purpose | Auth Required | Rate Limit |
|-------|---------|---------------|------------|
| `/api/mobile/*` | Mobile app requests | `X-Chronicle-App-Key` header | 5 req/s |
| `/api/web/*` | Frontend web app | `Authorization` header (JWT) | 20 req/s |
| `/chronicle/*`, `/datastore/*` | Blocked | N/A | Returns 404 |

### Mobile API (`/api/mobile/*`)

- Requires `X-Chronicle-App-Key` header for all requests
- Limited to `GET` and `POST` methods only
- Strict rate limiting (5 req/s, burst 10)
- Paths are stripped: `/api/mobile/chronicle/v3/...` → `/chronicle/v3/...`

### Web API (`/api/web/*`)

- Requires `Authorization: Bearer <token>` header
- All HTTP methods allowed
- Higher rate limits (20 req/s, burst 30)
- Paths are stripped: `/api/web/chronicle/v3/...` → `/chronicle/v3/...`

### Direct Backend Access (Blocked)

Direct routes like `/chronicle/*`, `/datastore/*`, `/principal/*` return 404.
All requests must go through `/api/mobile/` or `/api/web/`.

---

## Mobile App Configuration

The Chronicle Android app needs to be configured for your deployment.

### 1. Update Base URL

In `chronicle/app/src/main/java/com/openlattice/chronicle/services/upload/UploadWorker.kt`:

```kotlin
// Change:
const val PRODUCTION = "https://chronicle-screentime-app.research.bcm.edu"

// To:
const val PRODUCTION = "https://your-domain.com/api/mobile"
```

### 2. Add App Key Header

The app must send the `X-Chronicle-App-Key` header with every request.
The key value should match `MOBILE_APP_KEY` in your `.env` file.

Generate a key:
```bash
openssl rand -hex 32
```

Add to your HTTP client configuration:
```kotlin
httpClient.addHeader("X-Chronicle-App-Key", BuildConfig.CHRONICLE_APP_KEY)
```

### 3. Build APK

```bash
cd chronicle
./gradlew assembleDebug
```

Output: `app/build/outputs/apk/debug/app-debug.apk`

### 4. Install

```bash
adb install app/build/outputs/apk/debug/app-debug.apk
```

### Endpoints Used by App

All endpoints are prefixed with `/api/mobile`:

| Endpoint | Purpose |
|----------|---------|
| `POST /api/mobile/chronicle/v3/study/{studyId}/participant/{participantId}/enroll` | Device enrollment |
| `POST /api/mobile/chronicle/v3/study/{studyId}/participant/{participantId}/android/upload` | Upload usage data |
| `GET /api/mobile/chronicle/study/{studyId}/participant/{participantId}/status` | Check participation |
| `GET /api/mobile/chronicle/study/{studyId}/questionnaires` | Get questionnaires |

---

## Data Encryption at Rest (HIPAA/GDPR Compliance)

Chronicle uses Percona's pg_tde extension for Transparent Data Encryption (TDE) of PostgreSQL data at rest. This is **required for HIPAA compliance** as PHI must be encrypted when stored.

### Encryption Overview

| Component | Encryption Method | Key Management |
|-----------|-------------------|----------------|
| PostgreSQL data files | AES-256 via pg_tde | File-based (dev) or Vault (prod) |
| WAL files | AES-256 via pg_tde | Same as data files |
| Backups | Encrypted at source | Key required for restore |

### Quick Start (Development)

For development/testing, the default file-based key provider is used:

```bash
# Default configuration in .env
PG_TDE_KEY_PROVIDER=file

# Start with encryption enabled (happens automatically)
docker-compose -f docker-compose.prod.yml up -d

# Verify encryption is working
docker-compose -f docker-compose.prod.yml exec postgres psql -U chronicle -d chronicle -c "SELECT * FROM pg_tde_list_key_providers();"
```

### Production Setup with HashiCorp Vault

For production deployments, use HashiCorp Vault for secure key management:

#### 1. Configure Vault

```bash
# Enable KV secrets engine v2
vault secrets enable -version=2 -path=secret kv

# Create policy for Chronicle TDE
vault policy write chronicle-tde - <<EOF
path "secret/data/chronicle/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/chronicle/*" {
  capabilities = ["list"]
}
EOF

# Create token for Chronicle
vault token create -policy=chronicle-tde -ttl=8760h
```

#### 2. Configure Environment

```bash
# In .env file
PG_TDE_KEY_PROVIDER=vault
PG_TDE_VAULT_URL=https://vault.example.com:8200
PG_TDE_VAULT_TOKEN=hvs.XXXXXXXXXXXXXXXXXXXX
PG_TDE_VAULT_MOUNT_PATH=secret
# PG_TDE_VAULT_CA_PATH=/etc/ssl/certs/vault-ca.pem  # If using self-signed cert
```

#### 3. Deploy

```bash
docker-compose -f docker-compose.prod.yml up -d
```

### Creating Encrypted Tables

Chronicle tables containing PHI should use the `tde_heap` access method:

```sql
-- Create new encrypted table
CREATE TABLE sensitive_data (
    id UUID PRIMARY KEY,
    participant_id UUID NOT NULL,
    phi_data JSONB
) USING tde_heap;

-- Convert existing table to encrypted
ALTER TABLE participants SET ACCESS METHOD tde_heap;

-- Verify table is encrypted
SELECT pgtde_is_encrypted('sensitive_data');
```

### Verifying Encryption

```bash
# Check encryption is enabled
docker-compose -f docker-compose.prod.yml exec postgres \
  psql -U chronicle -d chronicle -c "SELECT * FROM pg_tde_list_key_providers();"

# List encryption keys
docker-compose -f docker-compose.prod.yml exec postgres \
  psql -U chronicle -d chronicle -c "SELECT * FROM pg_tde_list_all_keys();"

# Verify a specific table is encrypted
docker-compose -f docker-compose.prod.yml exec postgres \
  psql -U chronicle -d chronicle -c "SELECT pgtde_is_encrypted('your_table_name');"
```

### Key Management Best Practices

| Environment | Key Provider | Backup Strategy |
|-------------|--------------|-----------------|
| Development | `file` | Not critical, can regenerate |
| Staging | `file` or `vault` | Regular volume snapshots |
| Production | `vault` | Vault auto-backup + key export |

**CRITICAL**: Without access to encryption keys, encrypted data is **permanently unrecoverable**.

#### Backing Up Keys (File Provider)

```bash
# Backup the TDE keyring volume
docker run --rm -v chronicle_postgres_tde_keyring:/keyring -v $(pwd):/backup \
  alpine tar czvf /backup/tde-keyring-backup-$(date +%Y%m%d).tar.gz /keyring

# Store backup in secure location (encrypted storage, separate from data backups)
```

#### Backing Up Keys (Vault Provider)

```bash
# Export keys from Vault (requires appropriate permissions)
vault kv get -format=json secret/chronicle/tde-keys > vault-tde-keys-backup.json

# Encrypt the backup
gpg --symmetric --cipher-algo AES256 vault-tde-keys-backup.json
rm vault-tde-keys-backup.json  # Remove unencrypted version
```

### Disaster Recovery

If the PostgreSQL container is destroyed but volumes are intact:

1. **File Provider**: Ensure `postgres_tde_keyring` volume is mounted
2. **Vault Provider**: Ensure Vault is accessible and token is valid
3. Start new container - keys will be automatically loaded

If keys are lost:

1. **Data is unrecoverable** - this is by design for security
2. Restore from backup (must include both data AND key backup)
3. For Vault: restore Vault backup first, then PostgreSQL backup

### Encryption Architecture

```
                    +------------------+
                    |   Application    |
                    +--------+---------+
                             |
                    +--------v---------+
                    |    PostgreSQL    |
                    |    with pg_tde   |
                    +--------+---------+
                             |
              +--------------+--------------+
              |                             |
    +---------v----------+       +----------v---------+
    |  File Key Provider |       | Vault Key Provider |
    |   (Development)    |       |   (Production)     |
    +--------------------+       +--------------------+
              |                             |
    +---------v----------+       +----------v---------+
    | Docker Volume      |       | HashiCorp Vault    |
    | /tde-keyring       |       | (External Service) |
    +--------------------+       +--------------------+
```

### Troubleshooting

| Issue | Solution |
|-------|----------|
| Extension not loading | Check `ENABLE_PG_TDE=1` is set |
| Key provider not found | Verify init script ran: check `docker logs chronicle-postgres` |
| Cannot decrypt data | Ensure correct key volume/Vault is accessible |
| Vault connection failed | Check URL, token, and network connectivity |
| Permission denied | Verify user 999:999 has access to volumes |

---

## Security Features

### API Route Separation
- **Mobile API** (`/api/mobile/*`): Requires app key, limited methods
- **Web API** (`/api/web/*`): Requires JWT auth, full access
- **Direct routes blocked**: `/chronicle/*`, `/datastore/*` return 404

### Rate Limiting
- Mobile API: 5 req/s (burst 10)
- Web API: 20 req/s (burst 30)
- General: 30 req/s (burst 50)
- Max 20 concurrent connections per IP

### Security Headers
- HSTS, X-Frame-Options, X-Content-Type-Options
- Content-Security-Policy, Referrer-Policy

### Network Isolation
- Only nginx exposed (ports 80, 443)
- Backend, frontend, postgres on internal network
- Direct backend access blocked at nginx level

---

## Maintenance

### Logs

```bash
docker-compose -f docker-compose.prod.yml logs -f
docker-compose -f docker-compose.prod.yml logs -f backend
```

### Restart

```bash
docker-compose -f docker-compose.prod.yml restart
```

### Update

```bash
git pull --recurse-submodules
docker-compose -f docker-compose.prod.yml up -d --build
```

### Database Backup

```bash
docker-compose -f docker-compose.prod.yml exec postgres \
  pg_dump -U chronicle chronicle > backup_$(date +%Y%m%d).sql
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| nginx won't start | Run `./init-ssl.sh` - certs may be missing |
| 502 Bad Gateway | Check `docker-compose logs backend` |
| Let's Encrypt fails | Ensure domain DNS points here, port 80 open |
| Mobile app can't connect | Verify APK has correct URL, check CORS in nginx logs |

---

## Architecture

```
                    Internet
                        │
        ┌───────────────┼───────────────┐
        │               │               │
   Mobile App      Web Browser     Blocked
        │               │               │
        ▼               ▼               ▼
┌─────────────────────────────────────────────────┐
│              nginx (:80, :443)                  │
│                                                 │
│  /api/mobile/* ──► backend (app key required)  │
│  /api/web/* ────► backend (JWT required)       │
│  /chronicle/* ──► 404 (blocked)                │
│  /* ────────────► frontend                     │
└─────────────────────────────────────────────────┘
              │                   │
              ▼                   ▼
        ┌─────────┐         ┌─────────┐
        │ backend │         │frontend │
        │(:40320) │         │  (:80)  │
        └────┬────┘         └─────────┘
             │
             ▼
       ┌──────────┐
       │ postgres │
       │  (:5432) │
       └──────────┘

All internal services on isolated Docker network.
Only nginx exposed to internet.
```

---

## Traefik Deployment

If you have an existing Traefik reverse proxy, use `docker-compose.traefik.yml` instead.

### Configuration

```bash
cp .env.example .env
nano .env
```

Additional settings for Traefik:

| Variable | Description | Default |
|----------|-------------|---------|
| `TRAEFIK_NETWORK` | Name of external Traefik network | `traefik` |
| `TRAEFIK_ENTRYPOINT` | HTTPS entrypoint name | `websecure` |
| `TRAEFIK_CERTRESOLVER` | Certificate resolver name | `letsencrypt` |

### Deploy

```bash
docker-compose -f docker-compose.traefik.yml up -d
```

### Route Configuration

The Traefik setup has the same API route separation:

- `/api/mobile/*` → backend (priority 20)
- `/api/web/*` → backend (priority 20)
- `/chronicle/*`, `/datastore/*` → blocked (priority 15)
- `/*` → frontend (priority 1)

---

## Temporal Workflow Engine (Optional)

Temporal provides durable workflow execution for long-running operations like notification delivery, upload processing, and scheduled study operations.

### Deploy with Temporal:

```bash
docker compose -p chronicle \
  -f docker-compose.traefik.yml \
  -f docker-compose.temporal.yml \
  up -d
```

Temporal creates two additional PostgreSQL databases (`temporal`, `temporal_visibility`) in the existing Postgres instance via the `auto-setup` image on first boot.

### Access:

- **Temporal UI**: `https://${DOMAIN}/temporal/` (IP-restricted to internal networks)
- **Admin CLI**: `docker compose --profile tools exec temporal-admin temporal workflow list`
- **gRPC endpoint** (for SDK workers): `temporal:7233` (internal network only)

### Configuration:

Dynamic config is at `docker/temporal/dynamic-config.yaml`. Changes take effect without restart. Key settings:
- `system.retention`: How long closed workflow history is kept (default: 90 days)
- `frontend.namespaceRPS`: Rate limit for SDK requests per namespace

## Security Overlay Deployment

Security configuration files are **not included in the git repository** for operational security. They exist on the server at deployment time.

### Required files (not in git — copy from server backup or generate fresh):

```
docker/docker-compose.security.yml     # CrowdSec, Vault, Fail2ban, Falco
docker/rotate-secrets.sh               # Secret rotation script
docker/security/                       # CrowdSec, Fail2ban, Falco, Vault configs
docker/traefik/dynamic/crowdsec-waf.yml.template  # WAF middleware template
tests/security/                        # Semgrep rules, security test suite
docs/SECURITY-*.md                     # Security documentation
```

### Deploy with security overlay:

```bash
# Base stack + security overlay
docker compose -p chronicle \
  -f docker-compose.traefik.yml \
  -f docker-compose.security.yml \
  up -d

# Initialize CrowdSec bouncer
docker exec chronicle-crowdsec cscli bouncers add traefik-bouncer
# Add the output key to .env as CROWDSEC_BOUNCER_API_KEY
# Restart Traefik to pick up the key

# Initialize Vault (if using)
docker exec chronicle-vault sh /vault/scripts/init-vault.sh
```

### Without security overlay:

The base `docker-compose.traefik.yml` includes a no-op WAF fallback middleware so routes work even without CrowdSec deployed. However, requests will not be inspected by the WAF.
