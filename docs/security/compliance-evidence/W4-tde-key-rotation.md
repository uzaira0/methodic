# W4 — TDE Principal-Key Rotation & Age Monitoring (HIPAA §164.312(a)(2)(iv))

**Workstream:** HIPAA-2028 Compliance Lane — W4 (encryption at rest/in transit, key management)
**Control:** HIPAA Security Rule §164.312(a)(2)(iv) — *Encryption and decryption / key management.*
**Status:** Implemented and test-covered. Rotation is an **operator-run / scheduled** action;
age monitoring runs automatically in the backend.
See the lane design: `docs/superpowers/specs/2026-06-13-hipaa-2028-compliance-lane-design.md` (§79–83).

---

## 1. Control mapping

Encryption at rest is provided by Percona PostgreSQL `pg_tde` (AES-256), whose **principal key**
wraps the per-table internal keys. The principal key is custodied in Vault (prod) or an on-host
file keyring (staging). HIPAA §164.312(a)(2)(iv) and the 2025 NPRM require **key management**,
which includes periodic key rotation. The gap this artifact closes:

- `scripts/rotate-secrets.sh` rotated app secrets (JWT, HMAC, DB password, CrowdSec key) but
  **explicitly skipped the TDE principal key**, and its comment implied the key was unrotatable.
- The hourly `EncryptionHealthService` verified that tables are encrypted, but **nothing tracked
  the principal key's rotation age** — a key could go years without rotation, unnoticed.

| Requirement | Mechanism | Evidence |
|---|---|---|
| §164.312(a)(2)(iv) periodic key rotation | `scripts/rotate-tde-principal-key.sh` rotates the pg_tde principal key (new key version → set as principal; re-wraps internal keys, no table re-encryption) | **`TdePrincipalKeyRotationTest`** — runs the script's exact rotation SQL against a real Percona `pg_tde` Testcontainer; plus the script's own `bash -n` / dry-run for both providers |
| §164.312(a)(2)(iv) key-management monitoring | `tde_principal_key` is a tracked secret in `SecretRotationService` (yearly cadence); age surfaced on `/internal/health/secrets` + Prometheus | `SecretRotationServiceTest` |

---

## 2. Rotation automation

**`scripts/rotate-tde-principal-key.sh`** (new):

- Selects the active provider exactly as `docker/init-db-encryption.sh` does:
  `PG_TDE_KEY_PROVIDER=vault` → `chronicle-vault`, otherwise `chronicle-file-vault`.
- Rotates by creating a new timestamped key version and promoting it to principal:
  ```sql
  SELECT pg_tde_create_key_using_database_key_provider('chronicle-principal-key-<ts>', '<provider>');
  SELECT pg_tde_set_key_using_database_key_provider('chronicle-principal-key-<ts>', '<provider>');
  ```
  This re-wraps the internal keys; **table data is not re-encrypted**, so rotation is online.
- Stamps the rotation into the monitoring table so age resets:
  ```sql
  INSERT INTO secret_rotation_tracking (secret_name, last_rotated, rotated_by, notes)
  VALUES ('tde_principal_key', NOW(), 'rotate-tde-principal-key.sh', '<new key name>')
  ON CONFLICT (secret_name) DO UPDATE SET last_rotated = EXCLUDED.last_rotated,
      rotated_by = EXCLUDED.rotated_by, notes = EXCLUDED.notes;
  ```
- On the Vault provider, also patches the Vault metadata (`rotated_at`, `rotated_key`) at
  `${PG_TDE_VAULT_MOUNT_PATH}/chronicle/tde-principal-key`, mirroring `init-vault.sh`.
- Supports `--dry-run` (prints SQL/actions, executes nothing). Reuses the DB-connection pattern
  (`docker exec … psql -v ON_ERROR_STOP=1`) and `.env`-authoritative config from `rotate-secrets.sh`.

**`scripts/rotate-secrets.sh`** (modified):

- The "cannot be auto-rotated" comment no longer implies the principal **key** is unrotatable
  (only the Vault auth **token** `PG_TDE_VAULT_TOKEN` remains externally managed).
- New `rotate_tde_principal_key()` helper delegates to the new script (passing `--dry-run`
  through); wired into the full rotation sequence and exposed via `--only TDE_PRINCIPAL_KEY`.
  The TDE key lives in pg_tde/Vault (not `.env`), so rotation sets no env and needs no service
  restart (re-wrap is online).

---

## 3. Age monitoring

`SecretRotationService` (`chronicle-server`, `/internal/health/secrets`, hourly+daily checks,
Prometheus textfile metrics) now tracks `tde_principal_key`:

- Added to `TRACKED_SECRETS`.
- Given a **yearly** overdue threshold via `MAX_AGE_DAYS_BY_SECRET = { tde_principal_key → 365 }`
  (the other secrets keep the 90-day default). A 90-day window would warn for most of the year
  given a realistic annual TDE-key cadence; §164.312(a)(2)(iv) calls for *periodic*, not 90-day.
- Age is read from the `last_rotated` value in `secret_rotation_tracking` (stamped by the
  rotation script in §2). If no row exists yet, the key reports `overdue` with an unknown
  last-rotated date (advisory `WARN`, HTTP 200 — not a hard failure).
- Surfaced as `chronicle_secret_rotation_age_days{secret_name="tde_principal_key"}` and
  `chronicle_secret_rotation_overdue{secret="tde_principal_key"}` for alerting.

---

## 4. Tests

- **`com.openlattice.chronicle.storage.tde.TdePrincipalKeyRotationTest`** (new — the rotation
  procedure integration test the design called for) — spins up the **exact production image**
  `percona/percona-distribution-postgresql:17.5-3` with `shared_preload_libraries=pg_tde` and the
  file key provider (mirrors `init-db-encryption.sh` in `file` mode), creates the principal key and
  an encrypted `tde_heap` table holding a PHI-like payload, then runs the **verbatim rotation SQL**
  from `scripts/rotate-tde-principal-key.sh`
  (`pg_tde_create_key_using_database_key_provider` + `pg_tde_set_key_using_database_key_provider`)
  and asserts the design's three properties:
  - `pg_tde_is_encrypted('…'::regclass)` is **true pre- AND post-rotation**;
  - the PHI payload is **still readable, unchanged** after rotation (online re-wrap, no
    re-encryption) — re-verified on a **brand-new connection** so the rotation is proven durable,
    not session-local;
  - `pg_tde_key_info()` advances to the rotated key version.

  If the Percona image is unavailable in the runner it SKIPS via JUnit `Assume` (documented
  staging-smoke fallback), so an offline CI never red-builds. **Verified locally**:
  `JAVA_HOME=…/jdk21 ./gradlew :chronicle-server:test --tests "*TdePrincipalKeyRotationTest"` →
  1 test, 0 skipped, 0 failures (the image is present on the host).
- **`com.openlattice.chronicle.services.security.SecretRotationServiceTest`** — proves:
  `tde_principal_key` is tracked; its threshold is 365 days while others stay 90; a 200-day-old
  TDE key is **not** overdue but a 200-day-old 90-day secret **is** (per-secret cadence works);
  a 400-day-old key is overdue; an un-rotated key reports `overdue` with a null last-rotated; the
  `/internal/health/secrets` body carries `tde_principal_key` with `max_age_days=365`.
- Existing **`EncryptionHealthServiceTest`** unchanged and still green (no regression to the
  at-rest table-encryption verification).

---

## 5. How to operate

1. **Schedule rotation** on a yearly cadence (or on suspected compromise) via the self-hosted
   runner / cron that already runs `rotate-secrets.sh` — either `rotate-secrets.sh --only
   TDE_PRINCIPAL_KEY` or the full sequence. (Per project memory, GitHub-hosted Actions are
   broken on these repos; use the local/self-hosted scheduler.)
2. **Verify** post-rotation: `GET /internal/health/secrets` shows `tde_principal_key` with a
   fresh `age_days` and `overdue=false`; `EncryptionHealthService` still reports all tables
   encrypted.
3. **Alert** on `chronicle_secret_rotation_overdue{secret="tde_principal_key"} == 1`.

---

## 6. Source pointers

- **Rotation script:** `scripts/rotate-tde-principal-key.sh`
- **Rotation integration test:** `chronicle-server/src/test/kotlin/com/openlattice/chronicle/storage/tde/TdePrincipalKeyRotationTest.kt`
- **Orchestration:** `scripts/rotate-secrets.sh` — `rotate_tde_principal_key()`, `--only TDE_PRINCIPAL_KEY`.
- **Monitoring:** `chronicle-server/src/main/kotlin/com/openlattice/chronicle/services/security/SecretRotationService.kt`
  — `TRACKED_SECRETS`, `MAX_AGE_DAYS_BY_SECRET`, `maxAgeDaysFor()`.
- **Tracking table:** `secret_rotation_tracking` (created by `SecretRotationService.ensureTrackingTableExists`).
- **TDE init (provider + principal key names):** `docker/init-db-encryption.sh`, `docker/init-vault.sh`.
- **At-rest verification (unchanged):** `EncryptionHealthService` (`/internal/health/encryption`).
