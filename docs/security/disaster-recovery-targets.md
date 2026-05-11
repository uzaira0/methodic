# Chronicle Disaster Recovery Targets

Recovery Point Objective (RPO) and Recovery Time Objective (RTO) definitions for the Chronicle platform, with documented recovery procedures for each failure scenario.

---

## Recovery Point Objective (RPO)

| Mechanism | RPO | Description |
|-----------|-----|-------------|
| Streaming replication (hot standby) | ~0 (near-real-time) | Limited by WAL shipping lag. Replica receives changes within seconds of commit on primary. |
| Encrypted daily backups | <= 24 hours | Full `pg_dump` encrypted with AES-256-CBC (PBKDF2, 600k iterations). Runs nightly at 02:00 via cron. |
| Off-site replication | <= 24 hours | Backup artifacts rsynced/uploaded to off-site storage post-backup. |

---

## Recovery Time Objective (RTO)

| Scenario | RTO | Prerequisites |
|----------|-----|--------------|
| Primary DB failure with healthy replica | <= 5 minutes | Replica is streaming and caught up. |
| Primary + replica failure | <= 30 minutes | Latest encrypted backup available on local disk. Backup encryption key accessible. |
| Full site disaster (host loss) | <= 2 hours | Off-site backup available. New host provisionable. Backup encryption key stored separately from backup media. |
| TDE key loss | **UNRECOVERABLE** | Unless keyring backup exists. Without the TDE principal key, all `tde_heap` tables are permanently inaccessible. Verify keyring backup weekly. |

---

## Recovery Procedures

### A. Promote Replica (Primary DB Failure)

**When to use**: Primary PostgreSQL is down but the streaming replica is healthy and caught up.

```bash
# 1. Promote the replica to primary
docker exec postgres-replica pg_ctl promote -D /pgdata/data

# 2. Verify the replica accepted writes
docker exec postgres-replica psql -U chronicle -d chronicle \
  -c "SELECT pg_is_in_recovery();"
# Expected: f (false = no longer in recovery = accepting writes)

# 3. Update docker-compose to point the backend at the replica
#    Edit docker-compose.traefik.yml: change POSTGRES_HOST to replica hostname/IP

# 4. Restart the backend to pick up the new connection
docker compose restart chronicle-backend

# 5. Verify backend health
curl -s http://localhost:40320/internal/health | jq .

# 6. Once stable, rebuild the original primary as a new replica from the promoted node
```

**Post-recovery**: Rebuild the old primary as a streaming replica to restore redundancy.

---

### B. Restore from Encrypted Backup (Primary + Replica Failure)

**When to use**: Both primary and replica are lost. Latest encrypted backup is available on disk.

```bash
# 1. Verify the latest backup is intact
./docker/backup-chronicle.sh --verify

# 2. List available backups to select the most recent
./docker/backup-chronicle.sh --list

# 3. Decrypt the database dump
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -pass file:/etc/chronicle/backup-encryption-key \
  -in /opt/chronicle/backups/latest/chronicle-backup.dump.enc \
  -out /tmp/restore.dump

# 4. Start only PostgreSQL (not the full stack)
docker compose up -d chronicle-postgres

# 5. Wait for PostgreSQL to be ready
until docker exec chronicle-postgres pg_isready -U chronicle; do sleep 2; done

# 6. Restore the database
docker exec -i chronicle-postgres \
  pg_restore -U chronicle -d chronicle --clean --if-exists < /tmp/restore.dump

# 7. Securely delete the unencrypted dump
shred -u /tmp/restore.dump

# 8. Verify the restore
docker exec chronicle-postgres \
  psql -U chronicle -d chronicle -c "SELECT count(*) FROM studies;"

# 9. Restore TDE keyring (see section C below)

# 10. Start all services
docker compose up -d

# 11. Run health checks
curl -s http://localhost:40320/internal/health | jq .
./docker/verify-encryption.sh
```

**Alternative**: Use the guided restore script which handles all steps:
```bash
./docker/restore-chronicle.sh /opt/chronicle/backups/<BACKUP_DIR> /etc/chronicle/backup-encryption-key
```

---

### C. TDE Keyring Recovery

**When to use**: The TDE keyring directory (`/var/lib/postgresql/tde-keyring/`) is missing or corrupted. Without the keyring, all `tde_heap` tables are inaccessible.

```bash
# 1. Decrypt the keyring backup
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -pass file:/etc/chronicle/backup-encryption-key \
  -in /opt/chronicle/backups/latest/tde-keyring.tar.gz.enc \
  -out /tmp/tde-keyring.tar.gz

# 2. Restore the keyring to the PostgreSQL data directory
tar xzf /tmp/tde-keyring.tar.gz -C /var/lib/postgresql/

# 3. Set correct ownership and permissions
chown -R postgres:postgres /var/lib/postgresql/tde-keyring
chmod 700 /var/lib/postgresql/tde-keyring

# 4. Securely delete the unencrypted keyring
shred -u /tmp/tde-keyring.tar.gz

# 5. Restart PostgreSQL
docker compose restart chronicle-postgres

# 6. Verify encryption is working on all sensitive tables
docker exec chronicle-backend \
  curl -s http://localhost:40320/internal/health/encryption

# 7. Run the full verification script
./docker/verify-encryption.sh
```

**If keyring backup does not exist**: Use the Shamir secret sharing recovery process:
```bash
# Requires 3 of 5 key shares from the key ceremony
./docker/key-recovery.sh --type tde \
  --shares share-1.txt share-3.txt share-5.txt \
  --write-keyring
```

See `docker/key-ceremony.sh` for the initial key generation and share distribution process, and `docker/key-recovery.sh` for full recovery options.

---

### D. Full Site Disaster Recovery (Host Loss)

**When to use**: The entire host is lost. Restoring from off-site backup on a clean machine.

```bash
# 1. Provision a new host with Docker and Docker Compose installed

# 2. Clone the Chronicle repository
git clone <repository-url> /opt/chronicle
cd /opt/chronicle

# 3. Retrieve the backup encryption key from secure off-site storage
#    (This key MUST be stored separately from the backup media)
sudo mkdir -p /etc/chronicle
sudo cp <secure-source>/backup-encryption-key /etc/chronicle/backup-encryption-key
sudo chmod 600 /etc/chronicle/backup-encryption-key

# 4. Retrieve the latest off-site backup
mkdir -p /opt/chronicle/backups/latest
rsync <off-site-source>/latest/ /opt/chronicle/backups/latest/
# or: aws s3 sync s3://chronicle-backups/latest/ /opt/chronicle/backups/latest/

# 5. Copy environment configuration
cp docker/.env.production docker/.env

# 6. Run the guided restore
./docker/restore-chronicle.sh /opt/chronicle/backups/latest /etc/chronicle/backup-encryption-key

# 7. Verify all services are healthy
docker compose ps
curl -s http://localhost:40320/internal/health | jq .
./docker/verify-encryption.sh

# 8. Update DNS to point to the new host

# 9. Set up streaming replication to a new replica for redundancy
```

---

## Testing Schedule

| Frequency | Test | Owner | Verification |
|-----------|------|-------|-------------|
| **Weekly** | Automated backup restore test | CI workflow (GitHub Actions) | Backup decrypted, restored to temp DB, row counts validated, encryption verified |
| **Weekly** | TDE keyring backup integrity | CI workflow | Keyring backup decrypted and fingerprint compared |
| **Monthly** | Manual replica promotion drill | DBA | Promote replica, verify writes, rebuild old primary as replica |
| **Quarterly** | Full site disaster recovery drill | On-Call Engineer + DBA | Restore from off-site backup on a clean host, verify all services, run `verify-encryption.sh` |

**Drill documentation**: Use `docker/quarterly-restore-drill.sh` for the quarterly DR drill. Record results and file any issues found.

---

## Key File Locations

| File | Purpose | Backup Required |
|------|---------|----------------|
| `/etc/chronicle/backup-encryption-key` | Encrypts/decrypts all backup artifacts | YES (off-site, separate from backups) |
| `/var/lib/postgresql/tde-keyring/chronicle-keyring.per` | TDE principal key (file-based provider) | YES (included in nightly backup) |
| `/opt/chronicle/backups/` | Encrypted backup artifacts | YES (replicated off-site) |
| `docker/.env` / `docker/.env.production` | Environment configuration and secrets | YES (off-site) |
