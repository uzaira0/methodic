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
| Operator command failed | Open Operational Events and correlate its timestamp with logs | A setup, check, upgrade, restore, rotation, or shutdown command exited unsuccessfully. | Rerun `./chronicle doctor`, then follow the command-specific runbook printed by the failed command. |

## Viewer access

Grafana is never anonymous and never binds every interface. Create one account per trusted
observer with `./chronicle monitoring add-viewer NAME`; it receives only the Grafana Viewer
role. Remove or reset it with the corresponding `remove-viewer` or `reset-viewer` command.
No alert leaves the host: provisioned alerts remain visible in Grafana and notification
routing is permanently muted.

The shared log stream is deliberately not a copy of application logs. Fluent Bit emits
only timestamp, service, severity, normalized route, status, duration, request/error ID,
operation, result, failure category, release version, SQLSTATE, and exception class. Every
approved source uses a structured envelope. It discards messages, query strings, headers,
payloads, SQL text, stack traces, and identity/address fields before ingestion; unknown lines
are represented only as generic service/severity events.

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
