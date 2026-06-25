# Chronicle Disaster Recovery & Key-Escrow Runbook

Written 2026-06-23 after a fragility sweep. The headline risk: **the entire
database is unreadable without one 292-byte key file, and today every copy of
every key lives on the same `/home` disk as the data.** A single disk/host loss
= permanent, unrecoverable loss of all PHI ("completely secure, never
recoverable"). Fix that before anything else.

## The crypto keys and what each protects

| Key | Location (today) | If lost |
|-----|------------------|---------|
| **TDE principal key** (`chronicle-keyring.per`) | docker volume `chronicle_postgres_tde_keyring` → `/home/docker-data/volumes/chronicle_postgres_tde_keyring/_data` | All 63 `tde_heap` tables are AES-256 ciphertext with **no way back**. Total PHI loss. |
| **Backup encryption key** | `/home/uzair/.config/chronicle/backup-encryption-key` | Every encrypted backup (`database.dump.enc`, `tde-keyring.tar.gz.enc`, …) is undecryptable. Backups become useless. |
| `.env` secrets (JWT_SECRET, MOBILE_SIGNING_SECRET, POSTGRES_PASSWORD) | `/home/opt/chronicle/docker/.env` (0600) | Token/enrollment/auth breakage; recoverable by re-issuing, but disruptive. Included in backups. |

The nightly backup (`backup-chronicle.sh`) now bundles the TDE keyring inside
`tde-keyring.tar.gz.enc`, and the recovery chain is **verified** (keyring +
`PGDMP` dump both decrypt from the latest backup with the backup key). So a
backup *is* restorable — but only if the backup **and** the backup key survive.

## THE single point of failure (fix first)

`/home` (one 844 GB filesystem, ~92% full) holds the database, the WAL, the
backups (`/opt/chronicle/backups` is on `/home`), the TDE keyring, AND the
backup key — all of it. There is **no off-host copy of anything**. Disk failure
= everything gone together.

### Required action: off-host escrow (needs a destination you choose)
1. **Escrow the two critical keys off-host, offline.** Copy these to a password
   manager / HSM / offline encrypted media kept off this host:
   - `/home/docker-data/volumes/chronicle_postgres_tde_keyring/_data/chronicle-keyring.per`
   - `/home/uzair/.config/chronicle/backup-encryption-key`
   With these two + any backup, the DB is fully recoverable. Without them, it is not.
2. **Replicate backups off-host.** `docker/backup-replicate.sh` already exists
   (rsync-over-SSH or a mounted local target). Set `BACKUP_REMOTE_RSYNC=user@host:/path`
   in `.env` and add a cron after the 02:00 backup, e.g.:
   `15 2 * * * /opt/chronicle/docker/backup-replicate.sh --target rsync >> /var/log/chronicle-backup.log 2>&1`
   (Pick the destination host/path; it must not share `/home`'s failure domain.)

## Restore procedure (from an encrypted backup) — VALIDATED 2026-06-23
**Key fact, proven by a live drill (2026-06-23): the `database.dump.enc` is a
*logical* `pg_dump` of already-decrypted data, so it is keyring-INDEPENDENT.**
You do NOT need the old TDE keyring to recover the data — restore the logical
dump into any fresh pg_tde instance and it re-encrypts under a brand-new key.
The keyring backup (`tde-keyring.tar.gz.enc`) is only needed for a *physical* /
PITR restore from the data directory + WAL. So losing the live keyring is
survivable as long as the backup + backup key survive.

Logical restore (the normal path):
```
KEY=/etc/chronicle/backup-encryption-key      # or the escrowed copy
B=/opt/chronicle/backups/<timestamp>          # or the replicated copy
# 1. Decrypt the dump:
openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 600000 -in "$B/database.dump.enc" -pass file:$KEY > db.dump
# 2. Stand up a fresh Percona+pg_tde, init a NEW keyring, then restore:
docker run -d --name pg-restore -e POSTGRES_USER=chronicle -e POSTGRES_PASSWORD=... \
  -e POSTGRES_DB=chronicle percona/percona-distribution-postgresql:17.5-3 \
  -c shared_preload_libraries=pg_tde
docker exec -i pg-restore psql -U chronicle -d chronicle <<'SQL'
  CREATE EXTENSION IF NOT EXISTS pg_tde;
  SELECT pg_tde_add_database_key_provider_file('vault','/var/lib/postgresql/tde-keyring/keyring.per');
  SELECT pg_tde_create_key_using_database_key_provider('restore-key','vault');
  SELECT pg_tde_set_key_using_database_key_provider('restore-key','vault');
  CREATE ROLE chronicle_app NOLOGIN; CREATE ROLE chronicle_admin NOLOGIN;  -- so RLS policies restore cleanly
SQL
docker cp db.dump pg-restore:/tmp/db.dump
docker exec pg-restore pg_restore -U chronicle -d chronicle --no-owner --no-privileges -j2 /tmp/db.dump
```
Physical keyring restore (only for data-directory/PITR recovery):
```
openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 600000 -in "$B/tde-keyring.tar.gz.enc" -pass file:$KEY | tar -xzf -
# Place the keyring .per file into the keyring volume BEFORE starting postgres on the restored PGDATA.
```

## TDE principal-key rotation — DONE 2026-06-23 (re-run yearly)
`SecretRotationService` policy = 365-day max. Rotated 2026-06-23:
`chronicle-principal-key` → `chronicle-principal-key-20260623`, verified decrypt
on primary + replica + across a cold container recreate; `secret_rotation_tracking`
updated. The provider is **database-scoped** (`chronicle-file-vault`), and
pg_tde 2.0 requires **create-then-set** (the global-provider call in earlier
notes was wrong). Correct procedure:
```
-- take a fresh verified backup FIRST (./backup-chronicle.sh --full && --verify)
SELECT pg_tde_create_key_using_database_key_provider('chronicle-principal-key-<date>','chronicle-file-vault');
SELECT pg_tde_set_key_using_database_key_provider   ('chronicle-principal-key-<date>','chronicle-file-vault');
SELECT key_name FROM pg_tde_key_info();                          -- confirm new key active
SELECT pg_tde_verify_key();                                      -- confirm wrap intact
SET max_parallel_workers_per_gather=0; SELECT count(*) FROM android_sensor_data;  -- confirm decrypt
INSERT INTO secret_rotation_tracking (secret_name,last_rotated,rotated_by,notes)
  VALUES ('tde_principal_key',now(),'<who>','<key name>')
  ON CONFLICT (secret_name) DO UPDATE SET last_rotated=EXCLUDED.last_rotated, rotated_by=EXCLUDED.rotated_by, notes=EXCLUDED.notes;
```
Rotation is online (re-wraps internal keys; no full re-encryption). Primary and
replica **share** the `chronicle_postgres_tde_keyring` volume, so the new key is
visible to both immediately — no replica re-seed needed. If a row read fails
after rotation, stop and restore the previous keyring file from backup.

## Backup automation hardening (2026-06-23)
The nightly cron silently failed Jun 21–23 (and originally for ~17 days) because
the script defaults `KEY_FILE=/etc/chronicle/backup-encryption-key` and the key
lived only at `~/.config/chronicle/backup-encryption-key`. Fixed: the cron jobs
now set `CHRONICLE_BACKUP_KEY` **inline** (so a dropped crontab-env line can't
re-break it) and pin `PATH=/usr/local/bin:/usr/bin:/bin`. **Still recommended
(needs root):** also place the key at the script default so it works with zero
env dependency:
```
sudo install -d -m700 -o root -g root /etc/chronicle
sudo install -m600 -o root -g root ~/.config/chronicle/backup-encryption-key /etc/chronicle/backup-encryption-key
```
`/etc` is on `rhel-root`, not the 91%-full `rhel-home` — so this also moves one
key copy off the at-risk disk (still same host; off-HOST escrow below remains the
real fix).
