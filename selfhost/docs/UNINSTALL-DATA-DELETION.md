# Data Deletion and Uninstall

Chronicle has two different operations:

1. **Product data deletion** withdraws a participant or schedules a study for verified
   erasure while Chronicle remains installed.
2. **Uninstall** removes containers and, only when explicitly requested, storage owned by
   the installation.

Stopping or uninstalling containers is not proof that participant data was deleted.
Conversely, deleting a participant does not remove backups, exports, audit records, or the
Chronicle installation.

## Before deleting anything

1. Confirm the request and the study/participant identifiers through your approved process.
2. Check legal, ethics-board, sponsor, and institutional retention requirements. An active
   retention hold deliberately blocks physical erasure.
3. If data must be retained or transferred, open the study's **Bulk Downloads** tab, create
   the required full-study, Time Use Diary, and questionnaire exports, download each finished
   artifact, and verify that it opens before requesting deletion. Participant-only exports
   are under **Participants** > select rows > **Download Data**.
4. Record the request, scope, approver, study UUID, and later deletion operation UUIDs in the
   institution's controlled deletion register. Do not put participant identifiers in a
   public ticket or terminal transcript.

Downloaded exports and copies on analyst workstations are outside Chronicle. Inventory and
retain or destroy them under the same approved decision.

## Delete participant data

In the dashboard:

1. Open the study and select **Participants**.
2. Select one or more participants and choose **Delete**.
3. Read the confirmation and confirm the request.

Chronicle immediately changes each participant to `NOT_ENROLLED`, revokes form/export
access, and makes the participant's live rows inaccessible. It creates one
`WITHDRAW_AND_ERASE` operation per participant. Physical erasure starts only after the
seven-day quarantine and only when no retention hold applies.

The supported dashboard does not provide participant-deletion cancellation. Treat the
confirmation as final even though physical erasure is delayed.

## Delete a study

Archive the study first if the immediate goal is only to stop collection. Archiving is
reversible and is not deletion.

To request erasure:

1. Open the study's action menu and choose **Delete Study**.
2. Type the study title and choose **Schedule Deletion**.

Chronicle immediately quarantines participant data and schedules verified study erasure
after seven days. While the operation is still in quarantine, use the same action menu and
choose **Cancel Deletion** to reactivate the study. Cancellation is no longer possible after
the erasure worker starts.

## Verify deletion status and proof

Run this from the active release's `selfhost/` directory:

```bash
./chronicle deletion-status STUDY_UUID
```

To select one operation from the returned list:

```bash
./chronicle deletion-status STUDY_UUID OPERATION_UUID
```

The command validates both UUIDs before invoking Docker, sends them to PostgreSQL on stdin,
and does not display participant identifiers or proof hashes.

Interpret the result as follows:

| Field | Meaning |
|---|---|
| `status=QUARANTINED` | Live data is inaccessible; the seven-day delay has not elapsed. |
| `status=HELD` or `active_hold=t` | A retention hold is blocking erasure. Resolve it through the authorized retention-hold API/process; do not bypass it in SQL. |
| `status=ERASING` or `VERIFYING` | Physical deletion or residual-row verification is running. |
| `status=FAILED` | Erasure did not complete. Preserve the operation UUID and inspect backend logs before retrying or escalating. |
| `status=COMPLETED` and `proof_state=verified` | Every registered asset reported zero residual rows and the durable tombstone matches the operation proof. |
| `status=COMPLETED` and `proof_state=missing-proof` | Do **not** treat this as verified deletion. Preserve evidence and investigate. |
| `status=CANCELLED` | The operation was cancelled before erasure. |

No row is not deletion proof. Recheck the study UUID and the active installation.

## Researcher access and "account deletion"

The supported self-host release does not provide a durable multi-user account directory. It
uses one static `local-admin` application principal behind the private dashboard's shared
network boundary and global password. Deleting that principal through the generic Principal
API is not a supported account-deletion workflow: the configured principal is recreated at
backend restart.

To revoke an operator's access:

1. Remove that person's VPN/private-network access.
2. Rotate the shared dashboard credential: `./chronicle rotate-secret dashboard`.
3. Rotate the JWT signing secret to invalidate existing Chronicle sessions:
   `./chronicle rotate-secret jwt`.
4. Rotate any separately shared export, host, or backup credentials.

The source-only experimental Keycloak scaffold is not a supported release mode. If it was
used anyway, deleting its identity and sessions is a separate Keycloak operation; removing a
Chronicle principal does not delete the identity-provider account.

## Backups can retain deleted records

The database backup schedule is independent of the live deletion ledger. A dump made before
deletion can contain the deleted rows until that dump ages out. Defaults are 14 daily, 8
weekly, and 6 monthly copies (`BACKUP_KEEP_DAYS`, `BACKUP_KEEP_WEEKS`, and
`BACKUP_KEEP_MONTHS`). Off-host copies may have a different policy.

For each deletion request:

- record when the last pre-deletion backup expires or is approved for destruction;
- include off-host backup systems and manually copied dumps in that decision; and
- preserve any required deletion proof separately before removing the installation.

Restoring an old dump can reintroduce records that were deleted later. The guarded
`./chronicle restore` command checkpoints the newer withdrawal/deletion evidence, reapplies
credential and participation containment immediately, and the current backend refuses
readiness until it has verified exact completed proofs or physically replayed the missing
erasures, then written an immutable reconciliation receipt. A `--no-start` rollback is rejected when the selected backup lacks
any protected fact. Never bypass that command or remove its continuity checkpoint to force an
older binary to start.

## Stop Chronicle but keep all data

From the active `selfhost/` directory:

```bash
./chronicle down
# equivalent: docker compose down
```

This removes running containers and the Compose network. It intentionally retains named
volumes, `${CHRONICLE_STATE_DIR:-.}/backups`, TLS material, `.env`, and operator receipts.
Running `docker compose up -d` later reuses them.

## Remove the application and all installation storage

This is irreversible. Do it only after export verification, retention/hold review, and an
explicit decision about whether deletion tombstones and audit evidence must be preserved.

### 1. Record the exact ownership boundary

Do not source `.env` into the shell and do not print the whole file. Record only these two
non-secret settings and the current directory:

```bash
grep -E '^(COMPOSE_PROJECT_NAME|CHRONICLE_STATE_DIR)=' .env
pwd -P
```

Resolve `CHRONICLE_STATE_DIR` to one absolute path. A relative value is relative to this
`selfhost/` directory. If it is `.`, the release directory itself contains `backups/`,
`tls/`, receipts, and `.env` and will be deleted in the filesystem step below.

Inventory every Docker volume bearing the exact project label before removal:

```bash
docker volume ls \
  --filter 'label=com.docker.compose.project=EXACT_PROJECT_NAME' \
  --format '{{.Name}}'
```

The base release normally owns PostgreSQL data, the TDE keyring, audit logs, frontend files,
and Caddy data/config volumes. Monitoring adds VictoriaMetrics, VictoriaLogs, and Grafana
volumes. A volume from a formerly enabled overlay can remain even when that overlay is no
longer in `COMPOSE_FILE`, which is why the label inventory is required.

### 2. Remove the current Compose resources

With the exact active `.env` and `COMPOSE_FILE` still present:

```bash
docker compose down --volumes --remove-orphans
```

Then repeat the label inventory. For each remaining name, inspect it before removal:

```bash
docker volume inspect EXACT_VOLUME_NAME
docker volume rm EXACT_VOLUME_NAME
```

Run `docker volume rm` only for names whose
`com.docker.compose.project` label exactly matches the recorded project. Do not use a broad
`docker volume prune`, wildcard, or `xargs` command; other applications may share the host.

### 3. Remove bind-mounted state and release files

`docker compose down --volumes` does **not** remove bind-mounted files. The resolved state
directory can contain:

- plain SQL backups and the copied TDE keyring under `backups/`;
- TLS private keys and certificates under `tls/`;
- upgrade and secret-rotation receipts; and
- an interrupted-operation directory such as `.chronicle-secret-rotation`.

Inspect the exact path and nested mounts before deletion:

```bash
realpath /ABSOLUTE/CHRONICLE_STATE_DIR
find /ABSOLUTE/CHRONICLE_STATE_DIR -maxdepth 2 -mindepth 1 -print
findmnt -R /ABSOLUTE/CHRONICLE_STATE_DIR
```

Move outside that directory, type the exact absolute path to confirm it, and keep deletion on
one filesystem:

```bash
set -euo pipefail
STATE_TO_DELETE=/ABSOLUTE/CHRONICLE_STATE_DIR
case "$STATE_TO_DELETE" in
  ''|/|/home|/root|"$HOME") echo 'refusing unsafe state path' >&2; exit 1 ;;
esac
test "$STATE_TO_DELETE" = "$(realpath "$STATE_TO_DELETE")"
test -d "$STATE_TO_DELETE"
test ! -L "$STATE_TO_DELETE"
printf 'Type the exact path to destroy: %s\n' "$STATE_TO_DELETE"
IFS= read -r CONFIRM
test "$CONFIRM" = "$STATE_TO_DELETE"
cd /
rm -rf --one-file-system -- "$STATE_TO_DELETE"
```

If release bundles live outside that state directory, review and remove each exact release
directory separately. Their `.env` files contain credentials. Revoke/delete off-host backup
credentials and remove approved backup/export copies from their own systems; Docker cannot
do that for you.

Container images can remain safely as data-free application binaries and may be shared by
another installation. Remove only exact unused image digests after checking their consumers.

### 4. Verify the result

The following inventories should be empty for the recorded project:

```bash
docker ps -a \
  --filter 'label=com.docker.compose.project=EXACT_PROJECT_NAME' \
  --format '{{.Names}}'
docker volume ls \
  --filter 'label=com.docker.compose.project=EXACT_PROJECT_NAME' \
  --format '{{.Name}}'
```

Also verify that the reviewed state/release paths and approved off-host copies no longer
exist. Record the commands, approver, date, and retained proof in the controlled deletion
register. A clean Docker inventory alone does not prove that backups or exported files were
destroyed.
