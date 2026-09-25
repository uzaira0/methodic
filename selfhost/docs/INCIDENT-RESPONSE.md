# Security Incident Response

Use this when you suspect that someone reached data or credentials they should not have:
an unexpected login, a leaked `.env` or backup, a compromised host account, a lost laptop
with dashboard access, or a Chronicle security advisory that matches your version.

Run every command from the active bundle's `selfhost/` directory as the operator account.
Write down the time and the person for each step; regulators ask for that timeline.

## 1. Collect

Collect before you change anything, so the evidence reflects the incident and not the
clean-up. Keep the copies private (mode `0700` directory, on a host you control).

```bash
case_dir="$HOME/chronicle-incident-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$case_dir"
./chronicle doctor --json >"$case_dir/doctor.json"      # contains no secrets
./chronicle status >"$case_dir/status.txt" 2>&1
docker compose ps -a >"$case_dir/compose-ps.txt"
docker compose logs --timestamps --no-color >"$case_dir/compose.log" 2>&1
# Application and HIPAA audit log files (the file half of the audit trail)
docker compose cp backend:/var/log/chronicle "$case_dir/backend-logs"
# Database audit trail
docker compose exec -T postgres sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\copy (SELECT * FROM audit_logs) TO STDOUT WITH CSV HEADER"' \
  >"$case_dir/audit_logs.csv"
# Operator receipts: setup, upgrade, restore and rotation history
cp -a operator-receipts "$case_dir/" 2>/dev/null || true
ls -la --time-style=full-iso . backups backups/last >"$case_dir/file-listing.txt" 2>&1
```

Also keep the latest dump in `backups/` (do not let rotation delete it: copy it into the
case directory) and your reverse proxy / load balancer and host SSH logs.

Never copy `.env` into the case directory, a ticket, a chat or an e-mail, and never paste
its values anywhere. It stays mode `0600` where it is. Record only that it exists and its
modification time (`stat .env`).

## 2. Isolate

Pick the smallest step that stops the exposure:

- **Stop everything:** `./chronicle down`. Data and backups are kept; participants' phones
  queue uploads and retry later.
- **Shut the dashboard only:** remove the suspect source ranges from
  `DASHBOARD_ALLOWED_IPS` (or set it to `127.0.0.1/32`), or set `INTERNAL_BIND=127.0.0.1`,
  then `./chronicle up`. Mobile ingest keeps working.
- **Shut the public listener:** remove the route on your load balancer, or stop `web`
  with `docker compose stop web`.
- **Suspected host compromise:** take the host off the network and treat everything on it,
  including `backups/` and the keyring copy, as exposed. Rebuild on a clean host from a
  release bundle and restore from a backup taken before the compromise
  ([BACKUP-RESTORE.md](BACKUP-RESTORE.md)).

## 3. Rotate

Rotate every credential the attacker could have seen. Each command below has rollback and
writes a mode-`0600` receipt; details are in [SECRET-ROTATION.md](SECRET-ROTATION.md).

| Suspected exposure | Rotate |
|---|---|
| Dashboard password | `./chronicle rotate-secret dashboard` |
| Researcher sessions / JWT key | `./chronicle rotate-secret jwt` |
| `.env` file or host account | all of: `dashboard`, `jwt`, `internal-web`, `metrics`, `postgres`, `grafana` (if monitoring is on), `reviewer` (if enabled), `mobile begin` (only for a legacy HMAC fleet), then `tde` |
| Backups or the keyring copy | `./chronicle rotate-secret tde`, then destroy the exposed copies |
| Play Console reviewer credential | `./chronicle rotate-secret reviewer` |

Per-device mobile API keys are revoked when a participant is withdrawn from the dashboard.
Also revoke VPN/SSH access for any person or key involved, and rotate any host, backup or
object-storage credentials that are not in `.env`.

## 4. Notify

Decide with your institution, in writing, who must be told and by when. The clocks start
when you become aware of the breach, not when the investigation ends.

- **Your institution:** the information-security office, the Data Protection Officer, and
  the IRB / ethics committee that approved the study.
- **Chile (Ley 21.719):** notify the Agencia de Protección de Datos Personales without
  undue delay (target about 72 hours), and affected individuals for high-risk breaches.
  See [CHILE-LEY-21719.md](CHILE-LEY-21719.md).
- **GDPR:** the supervisory authority within 72 hours.
- **HIPAA:** affected individuals without unreasonable delay and no later than 60 days
  after discovery; HHS, and the media for 500 or more residents of one state.
- **Chronicle maintainers:** if the cause may be a Chronicle defect, report it privately
  through GitHub's private vulnerability reporting, as described in `SECURITY.md` at the
  bundle root. Do not open a public issue.

This runbook is not legal advice; confirm the duties that apply to your study with your
institution's counsel.

## 5. Recover and review

1. Upgrade to the fixed release if one exists: `./chronicle update`.
2. `./chronicle up`, `./chronicle verify`, `./chronicle doctor`.
3. Confirm that the rotated credentials work and the old ones fail.
4. Write a short review: timeline, cause, data affected, notifications sent, and what
   changes. Keep it with the case directory for the study's retention period.
