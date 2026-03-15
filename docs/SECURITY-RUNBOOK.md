# Chronicle Security Runbook

Operational security procedures for the Chronicle deployment. All commands assume you are working from `/opt/chronicle/docker/` unless otherwise noted.

---

## 1. Credential Rotation

### 1.1 JWT Secret Rotation

1. Edit `docker/.env`, update `JWT_SECRET` to a new high-entropy value.
2. Regenerate the frontend token:
   ```bash
   docker/generate-jwt.sh --write-config
   ```
3. Restart the frontend container:
   ```bash
   docker compose -f docker-compose.traefik.yml -p chronicle restart chronicle-frontend
   ```
4. **Impact:** All existing JWTs become invalid. Users will need to re-authenticate (the 401 interceptor in the frontend handles this automatically for active sessions).

### 1.2 Database Password Rotation

1. Edit `docker/.env`, update `POSTGRES_PASSWORD`.
2. Change the password inside PostgreSQL:
   ```bash
   docker exec chronicle-postgres psql -U chronicle -c "ALTER USER chronicle WITH PASSWORD 'new_password';"
   ```
3. Restart the backend so it picks up the new credential:
   ```bash
   docker compose -f docker-compose.traefik.yml -p chronicle restart chronicle-backend
   ```
4. Verify connectivity:
   ```bash
   docker exec chronicle-postgres psql -U chronicle -c "SELECT 1;"
   ```

### 1.3 Grafana Admin Password

1. Edit `docker/.env`, update `GRAFANA_ADMIN_PASSWORD`.
2. Restart the Grafana container:
   ```bash
   docker compose -f docker-compose.traefik.yml -p chronicle restart grafana
   ```

---

## 2. Incident Response

### 2.1 Suspected Compromise

1. Run the IR readiness checklist:
   ```bash
   tests/security/ir-drill-checklist.sh
   ```
2. Query Loki for audit events in the suspicious time window:
   ```bash
   curl 'http://localhost:3100/loki/api/v1/query_range?query={job="audit_logs"}&start=<unix_ts>&end=<unix_ts>'
   ```
3. Check Falco alerts for runtime anomalies:
   ```bash
   docker logs chronicle-falco 2>&1 | grep -i "warning\|critical"
   ```
4. Rotate all credentials immediately (see Section 1).
5. Create a backup before any remediation changes are made:
   ```bash
   docker/backup-chronicle.sh --full
   ```

### 2.2 Data Breach Notification

- **HIPAA:** Notify HHS within 60 days of discovery (45 CFR 164.408).
- **GDPR:** Notify the supervisory authority within 72 hours (Art. 33).
- **Documentation requirements:** Record what data was affected, how many records, the timeline of events, and all containment actions taken.

---

## 3. Vault Operations

### 3.1 Initial Setup

1. Initialize the Vault instance:
   ```bash
   docker exec chronicle-vault sh /vault/scripts/init-vault.sh
   ```
2. Save the unseal keys and root token securely (NOT in `.env` or any file in the repository).
3. Seed application secrets:
   ```bash
   docker exec chronicle-vault vault kv put chronicle/database password=<pw>
   ```
4. Enable Vault audit logging:
   ```bash
   docker exec chronicle-vault vault audit enable file file_path=/vault/logs/audit.log
   ```

### 3.2 Unsealing After Restart

Vault seals itself on restart. You must provide 3 of the 5 unseal keys:

```bash
docker exec chronicle-vault vault operator unseal <key1>
docker exec chronicle-vault vault operator unseal <key2>
docker exec chronicle-vault vault operator unseal <key3>
```

Verify the Vault is unsealed:
```bash
docker exec chronicle-vault vault status
```

The output should show `Sealed: false`.

---

## 4. WAF Tuning

### 4.1 Investigating False Positives

1. Check WAF logs for blocked requests:
   ```bash
   docker logs chronicle-waf 2>&1 | grep "403\|blocked"
   ```
2. Identify the rule ID from the log entry.
3. Add an exclusion for the rule in `docker/security/coraza/Caddyfile`.
4. Test that the exclusion works and the WAF still blocks real attacks:
   ```bash
   tests/security/test-waf.sh
   ```
5. Restart the WAF:
   ```bash
   docker compose -f docker-compose.traefik.yml -f docker-compose.security.yml -p chronicle restart coraza-waf
   ```

### 4.2 Adding Custom Rules

1. Edit `docker/security/coraza/Caddyfile`.
2. Add the `SecRule` directive with the appropriate match and action.
3. Restart:
   ```bash
   docker compose -f docker-compose.traefik.yml -f docker-compose.security.yml -p chronicle restart coraza-waf
   ```

---

## 5. Fail2ban Management

### 5.1 Check Banned IPs

```bash
docker exec chronicle-fail2ban fail2ban-client status chronicle-ratelimit
docker exec chronicle-fail2ban fail2ban-client status chronicle-auth
```

### 5.2 Unban an IP

```bash
docker exec chronicle-fail2ban fail2ban-client set <jail> unbanip <IP>
```

Replace `<jail>` with `chronicle-ratelimit` or `chronicle-auth` as appropriate.

### 5.3 Adjusting Thresholds

1. Edit `docker/security/fail2ban/jail.local` (adjust `maxretry`, `findtime`, `bantime`).
2. Restart:
   ```bash
   docker compose -f docker-compose.traefik.yml -f docker-compose.security.yml -p chronicle restart fail2ban
   ```

---

## 6. Falco Alert Triage

### 6.1 Viewing Alerts

Recent alerts in container logs:
```bash
docker logs chronicle-falco 2>&1 | tail -50
```

Structured JSON events:
```bash
docker exec chronicle-falco cat /var/log/falco/events.json | jq . | tail -20
```

### 6.2 Common Alerts and Actions

| Alert | Severity | Action |
|-------|----------|--------|
| Terminal shell in container | Warning | Investigate who exec'd into the container and why. Verify it was authorized maintenance. |
| Package manager in container | Critical | Should never happen in production. Investigate immediately -- this may indicate a compromised container. |
| Outbound connection | Info | Verify the connection is expected (metrics push, log shipping, DNS). Unexpected outbound connections require investigation. |

---

## 7. Backup & Restore

### 7.1 Manual Backup

```bash
docker/backup-chronicle.sh --full
```

Verify the backup integrity:
```bash
docker/backup-chronicle.sh --verify
```

List existing backups:
```bash
docker/backup-chronicle.sh --list
```

### 7.2 Restore from Backup

```bash
docker/restore-chronicle.sh
```

This runs a guided interactive process. After restore:

1. Verify the TDE keyring is present at `/var/lib/postgresql/tde-keyring` inside the postgres container.
2. Verify row counts match the pre-backup state.

### 7.3 Backup Validation

Run the automated backup and disaster recovery test:
```bash
tests/security/backup-dr-test.sh
```

This validates tamper detection and encryption key integrity.

---

## 8. Security Scan Interpretation

### 8.1 Running Full Scan

```bash
tests/security/run-all-security.sh
```

Reports are written to `tests/security/reports/`.

### 8.2 Interpreting SARIF Results

| Severity | Response |
|----------|----------|
| CRITICAL / HIGH | Fix immediately -- production risk. |
| MEDIUM | Fix within the current sprint. |
| LOW / INFO | Track in backlog. |

Quick count of findings in a SARIF file:
```bash
python3 -c "import json; data=json.load(open('file.sarif')); print(len(data['runs'][0]['results']), 'findings')"
```

### 8.3 False Positive Management

- **Secret scanning:** Document exclusions in `tests/security/gitleaks.toml`.
- **Static analysis:** Add `# nosemgrep: <rule-id>` inline with a justification comment explaining why the finding is a false positive.

---

## 9. Security Overlay Deployment

### 9.1 First-Time Deploy

```bash
docker compose -f docker-compose.traefik.yml -f docker-compose.security.yml -p chronicle up -d
docker exec chronicle-vault sh /vault/scripts/init-vault.sh
# Save unseal keys securely
tests/security/test-waf.sh
tests/security/test-vault.sh
tests/security/test-fail2ban.sh
tests/security/test-falco.sh
```

### 9.2 Verifying Overlay Health

```bash
docker ps --filter "label=com.docker.compose.project=chronicle" --format 'table {{.Names}}\t{{.Status}}'
```

All security containers should show `Up` status. If any container is restarting, check its logs:
```bash
docker logs <container-name> 2>&1 | tail -30
```
