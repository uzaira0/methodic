# HIPAA-2028 Session Handoff — 2026-06-20

**Scope:** Landed the six-module batch, hardened HIPAA-2028 W1, verified W2, hardened role-init,
made Vault W2-ready, triaged dependabot. **Everything committed + pushed.** Two items remain,
both blocked on things not available from here (the test device + a persistent Vault).

**All repos pushed + in sync (no local-only work):**

| Repo | Branch | HEAD |
|------|--------|------|
| root (`uzaira0/methodic`) | `develop` | `92f7c10` |
| `chronicle` (android) | `develop` | `64a4309` |
| `chronicle-models` | `main` | `536d6c9` |
| `chronicle-server` | `develop` | `46df9493` |
| `chronicle-web` | `develop` | `422c32e4` |
| `chronicle-api` | `develop` | `eab85d4` |

Resume on another machine: clone root, `git submodule update --init --recursive`. Nothing is
local-only; a plain pull gets everything.

---

## What landed this session

### 1. Six sensing-expansion module batch — LANDED on protected develops
The previously-unpushed batch (sleep / activity_recognition / health_connect / connectivity_state
/ app_network_usage / device_settings) is merged. server/web/api `develop` are protected
(PR + rebase-merge only), so each went via a feature branch + PR, then rebase-merged:
PRs **#19 / #114 / #12** merged → server `8ea74697`, web `422c32e4`, api `eab85d4`; root pointers
repointed. The permission-grant-flow work (chronicle `f5ef584`) is also pushed.

### 2. HIPAA-2028 W1 — verified RLS engages + fixed a real prod audit-immutability gap
**RLS study-isolation DOES engage** on the live request path. The pool authenticates as the
superuser `chronicle` (so `pg_stat_activity.usename=chronicle`, `rolbypassrls=t` — do NOT read that
as "RLS bypassed"); `RLSAwareHikariDataSource` runs `SET ROLE chronicle_app` per request, `RESET ROLE`
on return; bootstrap/upgrade paths keep superuser. Live proof: under `chronicle_app` + empty
`app.authorized_studies`, `sleep_events` → 0 rows; as superuser → true count (2).

**Gap found + fixed:** `study_settings_audit` and `participant_collection_acknowledgment` were
**mutable/deletable by the app role** in prod — RLS was OFF on them and their V25/V26 `REVOKE`-based
immutability was silently defeated by the idempotent blanket `GRANT … ON ALL TABLES … TO chronicle_app`
in `init-db-roles.sql` (re-grants after the one-time revoke; the grant is the last writer). `audit_logs`
was unaffected because V2 used RLS *policies* (GRANT-proof), not REVOKE.
- **Fix:** `V44__audit_trail_rls_immutability.sql` + `AuditTrailRlsImmutabilityUpgrade` (pod bean) bring
  both trails to the `audit_logs` pattern — enable+force RLS, study-scoped SELECT
  (`chronicle_has_study_access`), INSERT allowed, UPDATE/DELETE `USING(false)`. GRANT-proof; superuser
  still purges. Regression test `AuditTrailImmutabilityRlsTest` (**8/8**) reproduces the prod condition
  (grants the role the full blanket privileges) and asserts RLS still blocks.
- **Applied to LIVE prod** + verified: UPDATE/DELETE now affect 0 rows, reads intact, isolation holds.
- Landed: server **PR #20** → `46df9493`, root pointer. Memory: `chronicle-audit-immutability-revoke-defeated`.

### 3. Role-init hardening (defense-in-depth)
`docker/init-db-roles.sql` now ends with a re-runnable, table-existence-guarded `REVOKE UPDATE, DELETE`
on the three audit tables from `chronicle_app` + `chronicle_admin`, so the blanket grant never reaches
them again (RLS is primary; this is belt-and-suspenders). **Applied to live prod** — `chronicle_app`
now has SELECT+INSERT but no UPDATE/DELETE on all three audit tables. Root `849ede3`.

### 4. HIPAA-2028 W2 (e2ee) — VERIFIED built, DORMANT (not greenfield)
The W2 spec said "current state: none," but e2ee is **fully built end-to-end** since the design:
- models: `crypto/{EncryptedEnvelope,EnvelopeCipher,EncryptedPayloadType}`, `study/StudyEncryptionSetting`
- Android: `services/crypto/PayloadSealer` (+ `EncryptionSettingStore`, `EncryptionRequiredButUnavailableException`), wired into every upload worker
- server: `services/crypto/{EnvelopeDecryptionService,StudyEncryptionKeyService,StudyKeyStore}` + `EncryptedPayloadUploadService` + V29; admin endpoint `POST /study/{id}/encryption/provision`
- **Verified: ~45 tests green** (models 13, cross-impl parity `ParityTest` 7, Android `PayloadSealer` 6, server EnvelopeRoundTrip 8 / EncryptedPayloadUpload 4 / EncryptedPayloadsRls 7).
- **Safe-by-default + dormant:** un-provisioned studies return a disabled setting → device uploads
  plaintext. **`encrypted_payloads` has 0 rows; no study has encryption enabled.** Engineering done;
  not activated.

### 5. Vault made W2-ready (NOT enabled on the live backend — that would break prod)
Investigated "enable Vault." The only wired Vault (`docker-compose.traefik.yml --profile vault`) is
**dev-mode** (`vault server -dev`, in-memory) and seeds **dev secret values**. Two showstoppers for the
live backend:
- `VaultSecretOverlayProcessor` overlays the **DB user/password** (every HikariCP pool) + Hazelcast
  passwords from Vault → enabling it would push `dev-db-password-not-for-production` into the prod pool →
  **backend can't connect → full prod outage.**
- Dev-mode storage is in-memory → a vault restart loses any W2 study keys → undecryptable ciphertext.

So I did **not** flip `VAULT_ENABLED` on prod. Instead, committed the missing readiness artifacts (root `6e72ca8`):
- `docker/vault/init-vault.sh` — production secret-seeding from real env (refuses dev/placeholder values
  and in-memory servers), prints the AppRole wiring. (The dev script's referenced prod counterpart didn't exist.)
- `docker/vault/chronicle-server-policy.hcl` — added `secret/data/encryption/*` (create/update/read) +
  metadata + deny-destroy. Previously the policy only covered read on `secret/data/chronicle/*`, so W2
  key provisioning (a write to `encryption/study/{studyId}/{keyId}`) would have been **denied even with
  Vault up**.

### 6. Dependabot triage
Merged the **8 safe GitHub Actions bumps** (CI-only, zero build/runtime impact; CI is infra-broken on
these repos anyway): root #70/#69/#68/#67/#66, android #12/#3/#1. Root pointer bumped (`92f7c10`).
- android **#2** (checkout 5→6) has a merge conflict — left OPEN; dependabot will rebase, or resolve later.
- **NOT merged (need deliberate handling):** all gradle bumps (#64/#63 Kotlin 2.3.21→**2.4.0**,
  #62 license-report, #61 spotbugs; android #8 gradle-wrapper 9.5, #7 androidx.sqlite, #6 jsr305, #5
  jackson) require regenerating `gradle/verification-metadata.xml` (`./gradlew --write-verification-metadata
  sha256 help`) or they checksum-fail the build. Major version bumps need migration/build testing:
  root #47 **postgres 17.6→18.4** (DB major — needs data migration), android #4 commons-io 2.5→2.22
  (also CONFLICTING), web #108 fast-uri 3→4.

---

## Remaining work (both blocked on things not available here)

### A. Activate W2 e2ee (needs a persistent Vault + the device)
W2 is code-complete but dormant. To turn it on **safely** (do NOT use dev-mode Vault):
1. Stand up a **persistent/external** Vault (raft/integrated storage or external cluster + auto-unseal).
2. Run `docker/vault/init-vault.sh` against it with the **real** secrets exported in env (sources from
   the live `.env`); note the AppRole id/secret it prints.
3. Set backend env `VAULT_ENABLED=true`, `VAULT_AUTH_METHOD=approle`, `VAULT_APP_ROLE_ID/SECRET_ID`,
   then restart the backend **in a maintenance window** (new hard dependency — verify it boots + DB
   connects before declaring success).
4. Provision a study key: `POST /chronicle/.../study/{studyId}/encryption/provision` (admin) → writes the
   public `StudyEncryptionSetting` into study settings, private key to Vault.
5. Device re-syncs settings → `PayloadSealer` encrypts → confirm `encrypted_payloads` rows appear and
   decrypt-on-read/export works. **This end-to-end confirmation needs the device (see B).**

### B. On-device QA (blocked — Pixel wifi-adb down)
Pending device confirmations: the permission-grant Data Sharing scrolled view; W2 device-side encryption;
plus the older QA debt (interaction_events / audio / notification modules — compile-verified, never
on-device QA'd). Recover adb: wake the tablet → re-enable Wireless debugging / re-run `adb tcpip` over USB
→ `adb connect <ip:port>`. **Never reboot it** (`adb tcpip` dies on reboot; needs USB to restore).

### C. Dependabot remainder
Regenerate verification metadata then merge the minor gradle bumps; handle postgres 18 / Kotlin 2.4 /
commons-io / fast-uri deliberately; rebase android #2.

## Resume environment
- JDK 21: `export JAVA_HOME=/home/uzair/.local/jdks/temurin-21`
- Backend tests from the **root** monorepo (`./gradlew :chronicle-server:test …`) — the standalone
  submodule build 401s on published artifacts. Android tests from `chronicle/` (`:app:testDebugUnitTest`).
- DB inspection: `docker exec -i -e PGPASSWORD="$(docker exec chronicle-backend printenv POSTGRES_PASSWORD)" chronicle-postgres psql -h 127.0.0.1 -U chronicle -d chronicle` (use `-i` for heredocs).
- Release APK: build with the live `MOBILE_SIGNING_SECRET` from the backend; R8 disabled for `release`.
