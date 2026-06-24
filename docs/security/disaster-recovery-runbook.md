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

## Restore procedure (from an encrypted backup)
```
KEY=/path/to/backup-encryption-key            # the escrowed copy
B=/opt/chronicle/backups/<timestamp>          # or the replicated copy
# 1. DB dump:
openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 600000 -in "$B/database.dump.enc" -pass file:$KEY > db.dump
# 2. TDE keyring (restore into the keyring volume BEFORE starting postgres):
openssl enc -aes-256-cbc -d -salt -pbkdf2 -iter 600000 -in "$B/tde-keyring.tar.gz.enc" -pass file:$KEY | tar -xzf -
# 3. Restore keyring file to the volume, start postgres, then pg_restore db.dump.
```

## TDE principal-key rotation (DEFERRED until escrow is done)
`SecretRotationService` warns the principal key has **never** been rotated (its
own policy = 365-day max). Rotation is supported (pg_tde 2.0):
```
SELECT pg_tde_set_key_using_global_key_provider('chronicle-principal-key-<date>', 'chronicle-file-vault');
SELECT pg_tde_key_info();                    -- confirm new version
SELECT count(*) FROM android_sensor_data;    -- confirm data still decrypts
-- then UPDATE secret_rotation_tracking SET last_rotated = now() WHERE secret='tde_principal_key';
```
**Do this only AFTER off-host escrow exists and a fresh verified backup is in
hand** — rotating the master key is the single operation most able to cause the
exact unrecoverable state we're guarding against. Take a backup immediately
before, and verify decryptability immediately after; if a row read fails, stop
and restore the previous keyring file.
