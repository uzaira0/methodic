# Chronicle Key Management Runbook

HIPAA §164.312(a)(2)(iv) -- Encryption and Decryption Key Management

This runbook covers the complete lifecycle of Chronicle's encryption keys: generation, distribution, storage, rotation, recovery, and decommissioning.

---

## Table of Contents

1. [Key Inventory](#key-inventory)
2. [Key Ceremony Procedure](#key-ceremony-procedure)
3. [Share Distribution Guidelines](#share-distribution-guidelines)
4. [Vault Setup (Production)](#vault-setup-production)
5. [Auto-Unseal Configuration](#auto-unseal-configuration)
6. [Key Recovery Procedures](#key-recovery-procedures)
7. [Key Rotation Schedule and Procedure](#key-rotation-schedule-and-procedure)
8. [Quarterly Restore Drill](#quarterly-restore-drill)
9. [Emergency Procedures](#emergency-procedures)

---

## Key Inventory

| Key | Purpose | Storage | Rotation |
|-----|---------|---------|----------|
| TDE Principal Key | Encrypts PostgreSQL data at rest (pg_tde) | Vault (prod) / File keyring (dev) | Annually |
| Backup Encryption Key | Encrypts database backups (AES-256-CBC) | /etc/chronicle/backup-encryption-key | Annually |
| JWT Signing Secret | Signs authentication tokens | .env / Vault | 90 days |
| HMAC Mobile Signing Key | Validates mobile app requests | .env (MOBILE_APP_KEY) | 90 days |
| PostgreSQL SSL Certs | Encryption in transit | docker/postgres-ssl/ | Annually |
| TLS Certificates | HTTPS termination (Let's Encrypt) | docker/certs/ | Auto-renewed |
| API Keys | Per-study API authentication | Database (api_keys table) | 90 days |

---

## Key Ceremony Procedure

A key ceremony generates encryption keys and splits them into Shamir shares so that no single person can reconstruct a key alone.

### Prerequisites

- At least 5 custodians identified and available
- Secure, air-gapped machine (or at minimum a trusted workstation with no network logging)
- Sealed tamper-evident envelopes or encrypted USB drives for share distribution
- `ssss-split` installed (preferred) or Python 3 available

### Procedure

1. **Prepare the workstation**
   ```bash
   # Verify tools are available
   command -v ssss-split && echo "ssss OK" || echo "Will use Python fallback"
   command -v openssl && echo "openssl OK"
   ```

2. **Run the key ceremony script**
   ```bash
   cd /opt/chronicle/docker
   ./key-ceremony.sh --output-dir /tmp/key-ceremony-$(date +%Y%m%d)
   ```

   To use an existing TDE key (e.g., during rotation):
   ```bash
   ./key-ceremony.sh --tde-key <hex-string> --backup-key-file /etc/chronicle/backup-encryption-key
   ```

3. **Verify the output**
   - `ceremony-record.json` contains key fingerprints (safe to keep)
   - `tde-shares/share-{1..5}.txt` -- one per custodian
   - `backup-shares/share-{1..5}.txt` -- one per custodian

4. **Distribute shares** (see next section)

5. **Securely delete the ceremony output**
   ```bash
   shred -u /tmp/key-ceremony-*/tde-shares/share-*.txt
   shred -u /tmp/key-ceremony-*/backup-shares/share-*.txt
   rm -rf /tmp/key-ceremony-*
   ```

6. **Record the ceremony** in the security log:
   - Date and time
   - Custodian names and share numbers
   - Key fingerprints from ceremony-record.json
   - Witness signatures (if required by policy)

---

## Share Distribution Guidelines

### Rules

1. **Different people**: Each share goes to a different custodian. No person holds two shares of the same key.
2. **Different locations**: Shares should be stored in physically separate locations.
3. **Sealed storage**: Use tamper-evident envelopes, hardware security modules, or encrypted USB drives.
4. **No digital copies**: Do not email, Slack, or upload shares to cloud storage.
5. **Access log**: Maintain a log of who holds which share number (NOT the share content).

### Recommended Custodian Assignments

| Share | Primary Custodian | Storage Location |
|-------|-------------------|------------------|
| 1 | CTO / Security Lead | Office safe |
| 2 | Lead DevOps Engineer | Separate office safe |
| 3 | DBA / Infrastructure Lead | Bank safe deposit box |
| 4 | Compliance Officer | Bank safe deposit box (different bank) |
| 5 | Off-site secure storage | Geographically separate disaster recovery site |

### Custodian Responsibilities

- Store the share securely and do not copy it
- Report immediately if a share is lost or compromised
- Be available for recovery within 4 hours (SLA)
- Participate in annual key rotation ceremonies

---

## Vault Setup (Production)

For production deployments, use HashiCorp Vault instead of file-based key storage.

### Initial Setup

```bash
cd /opt/chronicle/docker
./init-vault.sh --vault-addr https://vault.example.com:8200
```

This script will:
1. Initialize Vault with 5 unseal keys (3 threshold)
2. Enable KV v2 at the configured mount path
3. Store the TDE principal key
4. Create a `chronicle-tde-read` policy
5. Generate a scoped service token

### Apply to Chronicle

Copy the generated `.env` snippet into your production `.env`:
```bash
PG_TDE_KEY_PROVIDER=vault
PG_TDE_VAULT_URL=https://vault.example.com:8200
PG_TDE_VAULT_TOKEN=hvs.XXXXXXXXXXXXXXXXXXXX
PG_TDE_VAULT_MOUNT_PATH=secret
# PG_TDE_VAULT_CA_PATH=/etc/ssl/certs/vault-ca.pem
```

Then restart the PostgreSQL container:
```bash
docker compose -p chronicle -f docker-compose.traefik.yml restart postgres
```

### Vault Policies

The `chronicle-tde-read` policy grants read-only access to the TDE key path:
```hcl
path "secret/data/chronicle/tde-principal-key" {
    capabilities = ["read"]
}
```

---

## Auto-Unseal Configuration

In production, manual unsealing after every Vault restart is impractical. For
the local BCM deployment, prefer an on-prem HSM/KMS or a tightly controlled
operator unseal procedure until a local key-management target is selected.

### Verification

After configuring auto-unseal, restart Vault and verify:
```bash
vault status
# sealed = false (should auto-unseal)
```

---

## Key Recovery Procedures

### Scenario 1: TDE Principal Key Lost (File Provider)

The TDE keyring file at `/var/lib/postgresql/tde-keyring/` is corrupted or the volume is lost.

1. Contact at least 3 of 5 TDE key custodians
2. Collect their share files
3. Run recovery:
   ```bash
   ./key-recovery.sh --type tde \
       --shares custodian1-share.txt custodian3-share.txt custodian5-share.txt \
       --fingerprint <from-ceremony-record> \
       --write-keyring
   ```
4. Restart PostgreSQL
5. Verify TDE is functional:
   ```bash
   ./verify-encryption.sh
   ```

### Scenario 2: Backup Encryption Key Lost

The file at `/etc/chronicle/backup-encryption-key` is lost.

1. Contact at least 3 of 5 backup key custodians
2. Run recovery:
   ```bash
   ./key-recovery.sh --type backup \
       --shares share-2.txt share-3.txt share-4.txt \
       --fingerprint <from-ceremony-record> \
       --write-key-file
   ```
3. Verify by decrypting a known backup:
   ```bash
   ./backup-chronicle.sh --verify
   ```

### Scenario 3: Vault Unavailable

If the Vault server is down and PostgreSQL cannot start:

1. **Short-term**: Unseal Vault (requires 3 of 5 unseal keys from custodians)
2. **If Vault is destroyed**: Reconstruct the TDE key from Shamir shares, switch to file provider temporarily:
   ```bash
   # In .env
   PG_TDE_KEY_PROVIDER=file
   ```
   Then restore the key using key-recovery.sh and rebuild Vault.

### Scenario 4: Single Custodian Compromised

1. Immediately perform a key rotation (next section)
2. Re-run key ceremony with new shares
3. Revoke the compromised custodian's access
4. Update the custodian roster

---

## Key Rotation Schedule and Procedure

### Schedule

| Key | Rotation Interval | Next Due |
|-----|-------------------|----------|
| JWT Signing Secret | 90 days | Check `/internal/health/secrets` |
| HMAC Mobile Signing Key | 90 days | Check `/internal/health/secrets` |
| API Keys | 90 days | Check `/internal/health/secrets` |
| TDE Principal Key | Annually | January key ceremony |
| Backup Encryption Key | Annually | January key ceremony |
| PostgreSQL SSL Certs | Annually | `./init-postgres-ssl.sh` |
| Vault Service Token | Annually | Regenerate via `init-vault.sh --skip-init` |

### TDE Key Rotation Procedure

1. Generate new TDE key:
   ```bash
   NEW_KEY=$(openssl rand -hex 32)
   ```
2. Run key ceremony with the new key:
   ```bash
   ./key-ceremony.sh --tde-key "$NEW_KEY"
   ```
3. Store in Vault:
   ```bash
   vault kv put secret/chronicle/tde-principal-key key="$NEW_KEY" ...
   ```
4. Rotate in PostgreSQL:
   ```sql
   SELECT pg_tde_rotate_key('chronicle-principal-key', 'chronicle-vault');
   ```
5. Distribute new shares to custodians
6. Destroy old shares

### JWT / HMAC Key Rotation

1. Generate new secret:
   ```bash
   openssl rand -base64 64  # for JWT_SECRET
   openssl rand -hex 32     # for MOBILE_APP_KEY
   ```
2. Update `.env` with the new values
3. Restart the backend:
   ```bash
   docker compose -p chronicle -f docker-compose.traefik.yml restart backend
   ```
4. Note: Existing JWTs signed with the old key will be invalid. Coordinate with active users.

### Backup Key Rotation

1. Decrypt all existing backups with the old key (or accept they become unrecoverable)
2. Generate new key and run ceremony:
   ```bash
   ./key-ceremony.sh
   ```
3. Write the new key:
   ```bash
   # From ceremony output, or from recovery of new shares
   openssl rand -base64 64 | sudo tee /etc/chronicle/backup-encryption-key > /dev/null
   sudo chmod 600 /etc/chronicle/backup-encryption-key
   ```
4. Run a new backup immediately to verify
5. Distribute new shares

---

## Quarterly Restore Drill

HIPAA §164.308(a)(7)(ii)(D) requires testing of contingency plans.

### Schedule

Perform restore drills quarterly: January, April, July, October (first week).

### Procedure

1. Run the drill against the latest backup:
   ```bash
   cd /opt/chronicle/docker
   LATEST=$(ls -d /opt/chronicle/backups/[0-9]*_[0-9]* | sort -r | head -1)
   ./restore-drill.sh "$LATEST"
   ```

2. The script will:
   - Verify backup checksums
   - Decrypt the database dump
   - Restore to a temporary database (`chronicle_drill_test`)
   - Validate table counts and key table row counts
   - Drop the temporary database
   - Report PASS/FAIL

3. Review the output and file the result:
   - Results are appended to `/opt/chronicle/backups/drill-results.log`
   - Include the drill report in the quarterly compliance review

### Cron Automation

```bash
# Run quarterly drill on the 1st of Jan, Apr, Jul, Oct at 4am
0 4 1 1,4,7,10 * /opt/chronicle/docker/restore-drill.sh \
    "$(ls -d /opt/chronicle/backups/[0-9]*_[0-9]* | sort -r | head -1)" \
    >> /var/log/chronicle-drill.log 2>&1
```

### Failure Response

If the drill fails:
1. Investigate the specific failure (checksum, decryption, restore, validation)
2. Run `./backup-chronicle.sh --verify` to check the latest backup
3. If the backup is corrupted, check older backups
4. If decryption fails, verify the backup key is correct (compare fingerprint)
5. Document the failure and resolution in the compliance log

---

## Emergency Procedures

### Complete Key Loss

If all copies of a key are lost (fewer than 3 shares recoverable):

- **TDE Key**: Encrypted data is irrecoverable. Restore from an unencrypted backup if one exists, or from a backup encrypted with the backup key (which protects the TDE keyring).
- **Backup Key**: Encrypted backups are irrecoverable. Take a new backup immediately with a new key.

### Suspected Key Compromise

1. Rotate the compromised key immediately (see rotation procedures above)
2. Audit access logs for unauthorized use
3. Re-run the key ceremony with fresh shares
4. Notify the compliance officer
5. Document the incident per HIPAA breach notification requirements

### Vault Disaster Recovery

1. Restore Vault from its own backup (if using integrated storage)
2. Or reconstruct from unseal keys + re-initialize
3. Re-store all Chronicle secrets
4. Update service tokens
5. Verify PostgreSQL can read TDE keys
