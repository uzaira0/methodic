# Secret Rotation and Interrupted-Operation Recovery

Run rotation commands from the `selfhost/` directory of the release that currently owns
the deployment. They update the existing mode-`0600` `.env`; they never accept a secret as
a command argument and never print a generated or chosen value.

```bash
cd /absolute/path/to/chronicle-selfhost-<version>/selfhost
chmod 600 .env
./chronicle rotate-secret --help
```

`--yes` skips the impact confirmation. It does not make a password appear in shell history:
the dashboard password is still read silently, and all other values are generated directly
into `.env`. Each service reconciliation has a bounded wait (300 seconds by default, set by
`SECRET_ROTATION_WAIT_TIMEOUT_SECONDS`).

Before the first rotation after an upgrade, let the backend become healthy and run
`./chronicle verify`. The `secret_rotation_tracking` ledger is owned by Flyway migration
V83; the rotation command deliberately performs no runtime schema changes. A deployment
that has not completed its release migrations therefore fails closed instead of granting
the operator account permission to create or alter tables.

## What each command changes

| Command | Effect | Expected interruption |
|---|---|---|
| `./chronicle rotate-secret dashboard` | Reads a new password twice, hashes it in the digest-pinned Caddy image over stdin, recreates `web`, and proves the password opens the internal dashboard. Only the bcrypt hash is stored. | Existing dashboard connections may reconnect while `web` is recreated. |
| `./chronicle rotate-secret jwt` | Generates a 256-bit signing value and recreates `backend`. | All researcher sessions are invalidated and must sign in again. |
| `./chronicle rotate-secret internal-web` | Generates the Caddy-to-backend credential and recreates `backend` and `web` together. | API/dashboard requests may briefly retry. |
| `./chronicle rotate-secret reviewer` | Generates or rotates the reusable Play Console reviewer credential, enables its exact study-scoped route, and recreates `backend`. | The previous Console value immediately receives `401`; update Play Console in the same window. |
| `./chronicle rotate-secret metrics` | Generates the backend metrics credential and recreates `backend`. | Separately configured scrapers must be updated from the protected `.env`; the supported monitoring overlay currently scrapes cAdvisor, not this endpoint. |
| `./chronicle rotate-secret postgres` | Publishes a generated password, changes the live PostgreSQL role over stdin, then reconciles and health-checks the complete Compose stack. | This is the broadest restart; expect a short full-stack interruption. |
| `./chronicle rotate-secret grafana` | Uses Grafana's authenticated password API, recreates Grafana, and verifies the new login. | Grafana only; requires `overlays/monitoring.yml`. The generated value remains only in `.env`. |
| `./chronicle rotate-secret mobile begin` | For an already enabled controlled legacy fleet, generates a new HMAC compatibility key while retaining the old key as `MOBILE_SIGNING_SECRET_PREVIOUS`. Public clients use per-device keys and are unaffected. | Backend recreation; controlled legacy/research clients keep working during the overlap. |
| `./chronicle rotate-secret mobile finalize` | Removes the previous compatibility key after every supported controlled legacy client has moved. | Backend recreation; an old controlled client still carrying the previous key receives `401`. |
| `./chronicle rotate-secret mobile abort` | Restores the pre-rotation compatibility key and removes the overlap. | Backend recreation; use when a controlled legacy-client rollout must be abandoned. |
| `./chronicle rotate-secret tde` | Takes and gzip-verifies a fresh plain-SQL dump, activates a timestamped pg_tde principal key online, verifies all public tables remain encrypted, and atomically refreshes the backed-up keyring. | No PostgreSQL restart; requires encryption and the backups overlay. |

After any rotation, run:

```bash
./chronicle verify
# Internal-dashboard deployments can also prove the chosen password without shell history:
./chronicle verify --dashboard-password
```

For Grafana, open `.env` only in a trusted local editor and move the new password directly
to the password manager used by the operators. Do not use `cat .env`, paste the value into a
chat, or put it in a command line.

The same rule applies to `CHRONICLE_REVIEWER_ACCESS_SECRET`: copy it from a trusted editor
directly into Play Console. It is deliberately not printed by the rotation command. Set the
synthetic study UUID and non-PII participant ID first; the command refuses to generate or
enable the credential without both, and it queries the live database to require an active
study plus a synthetic participant in `ENROLLED` state. Run
`./chronicle doctor` first and require the `reviewer-scope` check to be `ok`. Rotation
invalidates the previous reusable value
immediately and does not broaden it beyond the exact reviewer bootstrap endpoint.

## Legacy mobile rotation

Public app builds must not contain this key. They enroll with a one-time link and then use
a per-device API key. The normal self-host configuration therefore keeps both legacy
booleans false and both shared-key slots blank. This section applies only to an explicitly
controlled legacy or research-client fleet whose `.env` already has both booleans true and
a generated current key. For those clients, `mobile begin` creates an overlap; it does not
update an installed app.

1. On the server, begin the overlap:

   ```bash
   ./chronicle rotate-secret mobile begin
   ```

2. Only if that controlled legacy fleet still requires a client-embedded compatibility key,
   use its trusted build workstation to seal the new current value without displaying it.
   Never run this for the Google Play/public build. Replace the host and release path below;
   the secret travels only through SSH and the pipe into the age sealer:

   ```bash
   ssh chronicle-host \
     'cd /absolute/path/to/current/selfhost && . ./.env && printf %s "$MOBILE_SIGNING_SECRET"' \
     | (cd chronicle-ios && scripts/seal-secret.sh mobile-signing-secret)
   ```

   Commit only `chronicle-ios/secrets/mobile-signing-secret.age`. Never commit `.env`, an
   unencrypted secret, `local.properties`, or `Chronicle.local.xcconfig`.

3. On each authorized build Mac, decrypt through the canonical generator:

   ```bash
   cd chronicle-ios
   scripts/decrypt-ios-secret.sh
   ```

   This regenerates the ignored `chronicle/Config/Chronicle.local.xcconfig`. The Android
   Gradle build also reads that generated file, so the same sealed value can build both iOS
   and Android without a second plaintext authority. An explicitly supplied, untracked
   `MOBILE_SIGNING_SECRET` environment value or Gradle property remains a supported local
   override.

4. Build, sign, distribute, and verify both supported clients. Allow enough time for every
   installed participant device to move to the new build. The backend intentionally accepts
   both keys during this interval.
5. Only after no supported installed build uses the old key:

   ```bash
   ./chronicle rotate-secret mobile finalize
   ```

If deployment must be abandoned before finalization, run `mobile abort`. Do not finalize
merely because the new build exists; old installed builds cannot discover the new key from
the server.

## TDE-specific recovery facts

The pre-rotation dump is written under:

```text
${CHRONICLE_STATE_DIR}/backups/secret-rotation/
```

It is ordinary compressed SQL and therefore as sensitive as the database. The completion
receipt records its path and SHA-256, not its contents. Rotation also runs the existing
`db-init` keyring-copy path after activating the key; that copy is atomic, byte-compared,
mode `0600`, and stored at `backups/keyring/chronicle-keyring.per`. Future `db-init` runs
preserve whichever principal key the database already reports as active instead of silently
returning to the bootstrap key.

Keep the whole `backups/` tree off-box as described in [BACKUP-RESTORE.md](BACKUP-RESTORE.md).
A valid SQL dump remains recoverable without pg_tde even if every keyring copy is lost.

## Automatic rollback

Before changing anything, the command creates this private transaction directory under the
resolved state directory:

```text
${CHRONICLE_STATE_DIR}/.chronicle-secret-rotation/
```

It contains the previous `.env` and non-secret operation metadata. PostgreSQL, Grafana, and
TDE rotations also know how to reverse the corresponding live external change. An ordinary
command failure triggers rollback automatically, reapplies the previous service
configuration, and removes the transaction only after rollback succeeds.

Do not run an upgrade, restore, and rotation at the same time. Each command refuses the
other operation locks and rechecks after acquiring its own lock, closing the concurrent
start race. A completed operation writes a private, secret-free JSON receipt under:

```text
${CHRONICLE_STATE_DIR}/operator-receipts/secret-rotations/
```

The receipt records the release, operation, completion time, and verification result. It
does not contain old/new passwords, hashes, JWT/HMAC values, or keyring bytes.

## Recover after a host crash or `kill -9`

A hard interruption can prevent the EXIT trap from running. If
`.chronicle-secret-rotation` remains:

1. **Do not delete, rename, edit, or copy it.** `old.env` is the only saved prior credential
   set and is itself sensitive.
2. Confirm no `rotate-secret.sh` process is still running. Recovery also refuses a recorded
   owner PID that still exists.
3. Inspect only non-secret status first:

   ```bash
   docker compose ps --all
   docker compose logs --tail=100 backend web postgres grafana
   ```

4. Choose one direction:

   ```bash
   # Keep and finish the credential already published in the current .env:
   ./chronicle rotate-secret recover --forward

   # Restore old.env and reconcile services to the pre-rotation credential:
   ./chronicle rotate-secret recover --rollback
   ```

Recovery does not trust the last phase label alone. It compares the current `.env` with the
saved file; for PostgreSQL and Grafana it probes both candidate credentials without putting
either in argv; for TDE it accepts only the saved old/new key names and verifies the active
provider. If a new value had not yet been durably published, forward recovery refuses and
tells you to roll back before starting a new rotation. If neither external credential works,
or TDE reports an unrelated key, recovery stops and preserves all evidence rather than
guessing.

For TDE, both candidate key files are individually atomically published and flushed to disk,
then a durable `tde-metadata-ready` phase marker is published before PostgreSQL key activation
is attempted. A transaction still at `prepared` is therefore pre-activation: only
`recover --rollback` is accepted, and it safely removes even partially written key metadata.
At or after `tde-metadata-ready`, recovery requires both private metadata files and reconciles
the live key instead of relying on the phase label to say whether the database transaction
committed.

The direction is restart-safe: if recovery itself is interrupted, run the same direction
again. Do not switch direction after a partial recovery without first diagnosing the
reported state. A successful recovery health-checks the affected services, writes a recovery
receipt, and only then removes the transaction directory. Dashboard forward recovery cannot
reconstruct the cleartext password from its hash, so it requires the follow-up
`./chronicle verify --dashboard-password` check.

If recovery still fails, preserve `.env`, the transaction directory, relevant container
logs, and the secret-free receipts. Do not paste either `.env` file into an issue or support
chat.

## Credentials not handled by this command

- **SMTP/provider credentials:** rotate them at the provider first, update `.env` in a
  trusted editor, then run `docker compose up -d --wait --wait-timeout 300 backend`. This is
  not automated because provider APIs and overlap behavior differ.
- **OIDC client secrets:** the release does not ship a supported OIDC/Keycloak overlay. Do
  not infer support from the source-only experimental scaffold.
- **TLS private keys and certificates:** use your institution/CA's issuance and revocation
  procedure. Replace the matching certificate/key pair atomically in the state-directory
  `tls/` path, preserve private-key mode `0600`, recreate `web`, and verify the served chain.
  `rotate-secret` does not generate or revoke certificates.
