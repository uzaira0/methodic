# Monitoring and alert runbook

Start with `./chronicle doctor`. It reports the failed check, likely cause, and recovery
command without exposing deployment secrets. After any repair, run `./chronicle doctor`
and `./chronicle verify`; both must pass.

| Alert | Confirm | Likely cause | Recover |
|---|---|---|---|
| Backend, database, or web down | `./chronicle status`; `./chronicle logs backend postgres web` | The first fatal log line normally identifies configuration, migration, disk, or dependency failure. | Correct that first failure and run `./chronicle up`. |
| TDE unhealthy | `./chronicle check`; `./chronicle logs db-init postgres` | Principal key unavailable, default table access method changed, or an application table is not encrypted. | Do not recreate the keyring. Follow the bundled TDE recovery guidance, run `./chronicle up`, and confirm the alert clears. |
| Public probe down | `curl -fsS "$CHRONICLE_PUBLIC_BASE_URL/health"` from a separate machine (use `https://$DOMAIN` when the override is blank) | DNS, certificate, load-balancer, firewall, or listener binding. | Repair the external path, then run `./chronicle verify`. |
| Logs or metrics down | `./chronicle monitoring status`; `./chronicle logs victoriametrics victorialogs fluent-bit operational-probe` | Full observability disk, invalid retention, unavailable plugin, or failed scrape credentials. | Correct the first error and run `docker compose up -d monitoring-config victoriametrics victorialogs fluent-bit grafana`. |
| Configuration invalid | `./chronicle check` | An edited `.env`, missing overlay, wildcard bind, weak credential, or missing certificate. | Correct every `FAIL` line and run `./chronicle up`. |
| Backup stale or invalid | `./chronicle logs db-backup`; `gzip -t backups/last/*.sql.gz` | Scheduler failure, unavailable database/backend, full disk, or corrupt file. | Correct the cause and run `docker compose restart db-backup`; verify a new dump. |
| Disk or inode pressure | `df -h`; `df -i`; inspect the Database and Storage dashboard | Database/export growth, retained backups, container logs, or observability storage. | Add disk first or remove only documented disposable artifacts; never delete database volumes. |
| Backend/upload/enrollment/export/deletion/database errors | Correlate the Application dashboard time with Operational Logs | Bad requests, incompatible clients, failed background work, database pressure, or a backend defect. | Follow the correlated error ID, correct the cause, and verify the error rate returns to zero. |
| Repeated restart or OOM | `docker inspect <container>`; compare memory panels to configured limits | Resource limit too small or runaway workload. | Raise the documented service limit only after identifying the pressured service. |
| Certificate expiry | `openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" </dev/null 2>/dev/null \| openssl x509 -noout -dates` | Upstream or local certificate was not renewed. | Replace/renew it and run `./chronicle verify`. |
| Dashboard sign-in failures | Application dashboard, `chronicle_api_errors_total` for `/v3/auth/dashboard-login` | Password guessing, or one user with a forgotten password. | Restrict `DASHBOARD_ALLOWED_IPS`; run `./chronicle rotate-secret dashboard` if the password may be known. |
| Permission or role change | Study audit log at the alert time | An administrator granted or revoked study access. | Confirm the change was expected. If not, revoke it, rotate that administrator's credential, and follow [INCIDENT-RESPONSE.md](INCIDENT-RESPONSE.md). |
| Operator command failed | Open Operational Events and correlate its timestamp with logs | A setup, check, upgrade, restore, rotation, or shutdown command exited unsuccessfully. | Rerun `./chronicle doctor`, then follow the command-specific runbook printed by the failed command. |

## Troubleshooting

| Failure | Confirm | Fix |
|---|---|---|
| Port in use | `./chronicle check` prints `PORT=N is already in use`; `ss -ltnp 'sport = :N'` names the holder | Stop the holder, or change that `*_PORT` in `.env`, then `./chronicle check && ./chronicle up`. |
| Wrong bind address | `./chronicle check` prints `*_BIND=... is not an address on this host` | Set that `*_BIND` in `.env` to one of the listed addresses, then `./chronicle check && ./chronicle up`. |
| Expired certificate (own TLS) | `openssl x509 -noout -enddate -in tls/cert.pem` | Replace `tls/cert.pem` and `tls/key.pem`, then `docker compose restart web && ./chronicle verify`. |
| Expired certificate (internal listener) | `openssl x509 -noout -enddate -in tls/internal-cert.pem` | Remove `tls/internal-cert.pem` and `tls/internal-key.pem`, then `./chronicle up` regenerates them. |
| Disk full | `df -h`; `./chronicle doctor` | Free or add space (never delete volumes), then `./chronicle up`. Postgres does not restart by itself after a failed start. |
| Migration failed (first install) | `./chronicle logs backend` shows the first Flyway error | Correct the cause it names and run `./chronicle up`. For an upgrade, follow [UPGRADE-ROLLBACK.md](UPGRADE-ROLLBACK.md) "If the command fails". |
| Upload rejected, clock skew | `timedatectl` shows `System clock synchronized: no` | `sudo timedatectl set-ntp true`; signed requests allow 30 s of skew. |

## Viewer access

Grafana is never anonymous and never binds every interface. Create one account per trusted
observer with `./chronicle monitoring add-viewer NAME`; it receives only the Grafana Viewer
role. Remove or reset it with the corresponding `remove-viewer` or `reset-viewer` command.
Provisioned alerts are always visible in Grafana. To send them to a person, see
"Attach a notification channel" below.

The shared log stream is deliberately not a copy of application logs. Fluent Bit emits
only timestamp, service, severity, normalized route, status, duration, request/error ID,
operation, result, failure category, release version, SQLSTATE, and exception class. Every
approved source uses a structured envelope. It discards messages, query strings, headers,
payloads, SQL text, stack traces, and identity/address fields before ingestion; unknown lines
are represented only as generic service/severity events.

## Attach a notification channel

Alerts reach a person only through a webhook. Grafana sends every firing alert with the label
`scope=selfhost` to one contact point, `chronicle-dashboard-only`, defined in
`monitoring/grafana-alerting/contactpoints.yml`. Its URL comes from
`CHRONICLE_ALERT_WEBHOOK_URL`. When that is unset, the URL is the closed discard port
`http://127.0.0.1:9`, so delivery fails and alerts stay in Grafana only.

1. Choose a receiver that accepts a JSON `POST`: a chat incoming webhook, a pager service,
   or an internal relay that forwards to email. Chronicle sends no email itself. Payloads
   hold only the alert name, labels, summary, and runbook link, never participant data.
2. In `.env`, add `CHRONICLE_ALERT_WEBHOOK_URL=https://...`. Many webhook URLs contain a
   token, so treat the value as a secret and never paste it into chat or a command line.
3. Apply it with `docker compose up -d grafana`. The value is carried forward by
   `./chronicle upgrade` with the rest of `.env`; do not edit `contactpoints.yml` itself,
   because an upgrade replaces the bundled files.
4. Send a test: in Grafana, sign in as the admin user, open Alerting > Contact points,
   select `chronicle-dashboard-only`, and choose Test. Confirm the message arrives.
5. Grouping is by alert name, severity, and service. Grafana waits 30 s before the first
   message and repeats an unresolved alert every 24 h.

Only `webhook` is provisioned. To use another Grafana contact point type, change `type`
and `settings` in `contactpoints.yml` and keep that change in your own configuration
management, since it is overwritten on upgrade.

## Single-node scale ladder

1. Add disk when free-space, inode, or predicted-growth panels show pressure.
2. Add RAM when PostgreSQL/backend memory or connection pressure is sustained; add CPU for
   sustained ingestion CPU after confirming disk is not the bottleneck.
3. Adjust the documented `*_MEM_LIMIT`, PostgreSQL, and JVM values together, then compare
   the same dashboard window before and after.
4. The tested ceiling is one backend, one PostgreSQL, and one instance of each selected
   sidecar on one host. Use the dashboards as the cutover signal because data volume and
   collection modules dominate capacity. Multiple backend replicas, HA PostgreSQL, or
   multi-node storage require a separate deployment rather than `docker compose up --scale`.
