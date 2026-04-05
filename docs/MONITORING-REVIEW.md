# Chronicle Monitoring Review

Reviewed: 2026-04-05

## Stack Overview

| Component | Version / Image | Purpose |
|-----------|----------------|---------|
| Prometheus | prom/prometheus:v3.10.0 | Metrics collection and alerting |
| Alertmanager | (configured at chronicle-alertmanager:9093) | Alert routing and deduplication |
| Grafana | (provisioned via file provider) | Dashboards and visualization |
| Loki | Loki 3.x (TSDB schema v13) | Log aggregation (audit logs) |
| Promtail | (configured in docker-compose) | Log shipping to Loki |

## Prometheus Configuration

**File**: `docker/monitoring/prometheus.yml`

- **Scrape interval**: 15 seconds
- **Evaluation interval**: 15 seconds
- **Scrape targets**: Single job `chronicle-backend` scraping `chronicle-backend:40320` at `/prometheus/`
- **Rule files**: `prometheus-rules.yml` (existing), `alert-rules.yml` (new)
- **Alertmanager**: Routes to `chronicle-alertmanager:9093`

### Metrics Available

The backend uses Dropwizard Metrics (Codahale) bridged to Prometheus format via `DropwizardExports` in `MetricsPod.java`. This exposes:

- **HikariCP connection pool metrics**: ActiveConnections, IdleConnections, PendingConnections, MaxConnections, TotalConnections, ConnectionTimeoutRate_total, Wait (quantiles), Usage (quantiles), ConnectionCreation (quantiles) -- for 3 pools
- **Dropwizard Timer metrics**: Per-endpoint request timing (via `@Timed` annotations)
- **Standard `up{}` metric**: Prometheus scrape target health

### What Is NOT Scraped

- **Traefik metrics**: Not configured as a scrape target. Traefik exposes Prometheus metrics that would provide HTTP status code breakdowns, request durations, and TLS certificate info.
- **Node exporter**: Not deployed. No host-level metrics (CPU, memory, disk, network).
- **PostgreSQL exporter**: Not deployed. No database-level metrics (query latency, cache hit ratio, replication lag).
- **Loki**: Not scraped for its own operational metrics.
- **CrowdSec**: No metrics endpoint configured.

## Alertmanager Configuration

**File**: `docker/monitoring/alertmanager.yml`

- **Grouping**: By `alertname` and `severity`
- **Group wait**: 30s, group interval 5m, repeat interval 4h
- **Critical alerts**: Repeat every 1 hour
- **Receivers**: Only a `default` receiver with empty `webhook_configs`
- **Email**: Commented out, with placeholder SMTP configuration
- **Inhibition**: Critical alerts suppress matching warning alerts

**Gap**: No active notification channel configured. Alerts fire and are logged to stdout (scraped by Promtail into Loki), but no email, Slack, PagerDuty, or webhook is actually sending notifications.

## Existing Alert Rules

**File**: `docker/monitoring/prometheus-rules.yml`

Three rule groups with 8 alerts total:

| Group | Alert | Severity | Threshold |
|-------|-------|----------|-----------|
| chronicle-security | DatabaseConnectionPoolExhausted | critical | >5 pending for 2m |
| chronicle-security | DatabaseConnectionPoolSaturated | warning | Active == Max for 5m |
| chronicle-security | DatabaseConnectionTimeouts | critical | Any timeout rate >0 |
| security_alerts | DatabaseConnectionExhaustion | critical | >5 pending for 2m |
| security_alerts | AllPoolsNearCapacity | warning | >90% for 5m |
| security_alerts | ConnectionTimeoutSpike | critical | >0.1/s for 2m |
| chronicle-reliability | BackendDown | critical | up==0 for 1m |
| chronicle-reliability | SlowDatabaseQueries | warning | p50 wait >500ms for 5m |

**Issues identified**:
- Duplicate coverage: `DatabaseConnectionPoolExhausted` and `DatabaseConnectionExhaustion` alert on the same condition
- Only Pool 1 is monitored in `security_alerts` group; `chronicle-security` covers all 3 pools
- No HTTP-level alerts (error rates, latency)
- No infrastructure alerts (disk, backup, encryption)
- No WAF/security alerts

## New Alert Rules

**File**: `docker/monitoring/alert-rules.yml` (created)

Added comprehensive alerting rules covering:

| Category | Alert | Condition |
|----------|-------|-----------|
| Availability | ChronicleServerDown | up==0 for 5 minutes |
| Errors | HighErrorRate | >5% 5xx over 5 minutes |
| Latency | UploadLatencyHigh | p95 > 2 seconds |
| Backup | BackupVerificationFailed | Metric == 0 |
| Backup | RestoreDrillFailed | Metric == 0 |
| Backup | BackupStale | No backup in 25 hours |
| Encryption | TDETableUnencrypted | Unencrypted tables > 0 |
| Encryption | EncryptionHealthCheckFailing | Probe failing 10m |
| Secrets | SecretRotationOverdue | Age > 90 days |
| Secrets | SecretRotationHealthFailing | Probe failing 10m |
| Disk | DiskSpaceLow | <10% free for 5m |
| Disk | DiskSpaceWarning | <20% free for 15m |
| Database | DatabaseConnectionPoolExhausted | >5 pending for 2m |
| Database | DatabaseConnectionPoolSaturated | Saturated for 5m |
| Database | DatabaseConnectionTimeouts | Any timeouts |
| WAF | CrowdSecHighBlockRate | >20% 403s over 10m |
| WAF | CrowdSecBouncerDown | Bouncer unreachable 5m |

The new file was also:
- Added to `prometheus.yml` rule_files
- Volume-mounted in `docker-compose.traefik.yml`

## Grafana Dashboards

Two dashboards provisioned via file provider:

### 1. Chronicle Audit Dashboard (`chronicle-audit.json`)
- **Datasource**: Loki
- **Panels**: Total Events, PHI Access Events, Failed Logins, Unauthorized Access, Events by Action (timeseries), PHI Access Over Time, Audit Log Stream
- **Tags**: chronicle, audit, hipaa, compliance
- **Refresh**: 30 seconds

### 2. Chronicle Backend Dashboard (`chronicle-backend.json`)
- **Datasource**: Prometheus
- **Panels**: Backend Status (up/down), Total Connections, Connection Timeouts, Pool 1/2/3 Connections (timeseries), Connection Wait Time p50/p95/p99, Connection Usage Time, Connection Creation Time, Connection Timeouts Over Time
- **Tags**: chronicle, backend, hikaricp
- **Refresh**: 30 seconds

## Loki Configuration

**File**: `docker/siem/loki-config.yml`

- **Retention**: 2190 days (6 years) -- HIPAA compliant
- **Schema**: Migrated from boltdb-shipper (v11) to TSDB (v13) for Loki 3.x
- **Ingestion limits**: 10 MB/s rate, 20 MB burst, 10k max streams, 256 KB max line
- **Compaction**: 10 minute interval with retention enforcement
- **Analytics reporting**: Disabled

## Gaps and Recommendations

### Critical Gaps

1. **No active notification channel**: Alertmanager has no configured webhook, email, or chat integration. Alerts fire silently into logs.

2. **No node exporter**: Host-level metrics (CPU, memory, disk I/O, network) are not collected. The disk space alerts in `alert-rules.yml` require `node_exporter` to be deployed.

3. **No PostgreSQL exporter**: Database performance metrics (query duration, dead tuples, cache hit ratio, replication lag, WAL size) are invisible. Only HikariCP client-side metrics are available.

4. **No Traefik metrics scraping**: HTTP-level metrics (status codes, request duration by route) are not collected. The error rate and latency alerts require Traefik's `/metrics` endpoint to be scraped.

5. **Backup/restore/encryption/secret metrics not exported**: EncryptionHealthService and SecretRotationService expose HTTP health endpoints but not Prometheus metrics. The new alert rules reference metrics (`chronicle_backup_verification_success`, `chronicle_tde_unencrypted_tables`, `chronicle_secret_rotation_age_days`) that need to be implemented via either:
   - Micrometer gauges in the Java services
   - A Prometheus textfile collector (sidecar writing `.prom` files)
   - A Prometheus Pushgateway (for batch jobs like backup scripts)

### Recommended Actions

1. **Configure Alertmanager notifications**: Enable email or webhook (Slack, PagerDuty, OpsGenie) in `alertmanager.yml`.

2. **Deploy node_exporter**: Add as a container in docker-compose for host metrics.

3. **Deploy postgres_exporter**: Add `prometheuscommunity/postgres-exporter` targeting the Chronicle database.

4. **Add Traefik scrape job**: Traefik already exposes metrics; add a Prometheus scrape config for it.

5. **Export custom Prometheus metrics**: Add Micrometer gauges for backup status, TDE health, and secret rotation age so the new alert rules can fire.

6. **Add a Grafana alerting dashboard**: Create a dashboard panel showing active alerts from Alertmanager.

7. **Deduplicate existing rules**: Consolidate overlapping alerts between `chronicle-security` and `security_alerts` groups in `prometheus-rules.yml`.

8. **Add SLO/SLI dashboards**: Define service-level objectives (e.g., 99.9% availability, p95 < 500ms) and track error budgets in Grafana.
