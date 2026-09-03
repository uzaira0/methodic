#!/usr/bin/env bash
set -Eeuo pipefail

: "${POSTGRES_HOST:=postgres}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_DB:=chronicle}"
: "${POSTGRES_USER:=chronicle}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${PROBE_INTERVAL_SECONDS:=30}"
: "${RELEASE_VERSION:=unknown}"
: "${DOMAIN:=unknown}"
: "${PUBLIC_HEALTH_URL:=}"
: "${INTERNAL_HEALTH_URL:=http://web/health}"
: "${LOGS_HEALTH_URL:=http://victorialogs:9428/health}"
: "${COMPOSE_FILE_SELECTION:=}"
: "${ENABLE_ENCRYPTION:=false}"
: "${METRICS_DISK_BUDGET_BYTES:=5368709120}"
: "${LOGS_DISK_BUDGET_BYTES:=5368709120}"
[[ -n "$PUBLIC_HEALTH_URL" ]] || PUBLIC_HEALTH_URL="https://${DOMAIN}/health"

[[ "$PROBE_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || exit 64
(( PROBE_INTERVAL_SECONDS <= 300 )) || exit 64
mkdir -p /metrics
umask 077

escape_label() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/[[:cntrl:]]//g'
}

file_epoch() {
  stat -c '%Y' "$1" 2>/dev/null || printf '0'
}

collect() {
  local now tmp db_up=0 web_up=0 public_up=0 logs_up=0 cert_expiry=0 backup_epoch=0 backup_valid=0 backups_expected=0
  local db_size=0 connections=0 max_connections=0 commits=0 rollbacks=0 deadlocks=0 flyway=0 tde_expected=0 tde_healthy=0
  local metrics_bytes=0 logs_bytes=0 backups_bytes=0 exports_bytes=0
  now="$(date +%s)"
  tmp="/metrics/.operational.prom.$$"
  [[ "$ENABLE_ENCRYPTION" == true ]] && tde_expected=1

  export PGPASSWORD="$POSTGRES_PASSWORD"
  if pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t 5 >/dev/null 2>&1; then
    db_up=1
    IFS='|' read -r db_size connections max_connections commits rollbacks deadlocks <<EOF || true
$(psql -X -qAt -v ON_ERROR_STOP=1 -F '|' -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT pg_database_size(current_database()),numbackends,current_setting('max_connections')::integer,xact_commit,xact_rollback,deadlocks FROM pg_stat_database WHERE datname=current_database()" 2>/dev/null || printf '0|0|0|0|0|0')
EOF
    flyway="$(psql -X -qAt -v ON_ERROR_STOP=1 -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
      -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
      "SELECT COALESCE(MAX(CASE WHEN version ~ '^[0-9]+$' THEN version::integer END),0) FROM flyway_schema_history WHERE success" 2>/dev/null || printf 0)"
    if [[ $tde_expected -eq 1 ]] && psql -X -qAt -v ON_ERROR_STOP=1 -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
      -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
      "SELECT CASE WHEN current_setting('default_table_access_method')='tde_heap' AND (SELECT key_name FROM pg_tde_key_info()) IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_am a ON a.oid=c.relam WHERE n.nspname='public' AND c.relkind='r' AND a.amname<>'tde_heap') THEN 1 ELSE 0 END" 2>/dev/null | grep -qx 1; then
      tde_healthy=1
    fi
  fi
  unset PGPASSWORD

  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 8 "$INTERNAL_HEALTH_URL" >/dev/null 2>&1 && web_up=1 || true
    curl -kfsS --max-time 10 "$PUBLIC_HEALTH_URL" >/dev/null 2>&1 && public_up=1 || true
    curl -fsS --max-time 8 "$LOGS_HEALTH_URL" >/dev/null 2>&1 && logs_up=1 || true
  elif command -v wget >/dev/null 2>&1; then
    wget -q --spider -T 8 "$INTERNAL_HEALTH_URL" >/dev/null 2>&1 && web_up=1 || true
    wget --no-check-certificate -q --spider -T 10 "$PUBLIC_HEALTH_URL" >/dev/null 2>&1 && public_up=1 || true
    wget -q --spider -T 8 "$LOGS_HEALTH_URL" >/dev/null 2>&1 && logs_up=1 || true
  fi

  local cert_file
  for cert_file in /tls/cert.pem /tls/internal-cert.pem; do
    if [[ -s "$cert_file" ]] && command -v openssl >/dev/null 2>&1; then
      local expiry_text expiry_candidate
      expiry_text="$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
      expiry_candidate="$(date -d "$expiry_text" +%s 2>/dev/null || printf 0)"
      (( expiry_candidate > cert_expiry )) && cert_expiry=$expiry_candidate
    fi
  done
  if (( cert_expiry == 0 )) && command -v timeout >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 && [[ "$DOMAIN" != unknown ]]; then
    local remote_cert
    remote_cert="$(timeout 8 openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
    [[ -n "$remote_cert" ]] && cert_expiry="$(date -d "$remote_cert" +%s 2>/dev/null || printf 0)"
  fi

  [[ "$COMPOSE_FILE_SELECTION" == *overlays/backups.yml* ]] && backups_expected=1
  local latest_backup=""
  if [[ -d /backups/last ]]; then
    latest_backup="$(find /backups/last -maxdepth 1 -type f -name '*.sql.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2- || true)"
  fi
  if [[ -n "$latest_backup" && -s "$latest_backup" ]]; then
    backup_epoch="$(file_epoch "$latest_backup")"
    gzip -t "$latest_backup" >/dev/null 2>&1 && backup_valid=1 || true
  fi
  metrics_bytes="$(du -sb /observability-data/metrics 2>/dev/null | awk '{print $1}' || printf 0)"
  logs_bytes="$(du -sb /observability-data/logs 2>/dev/null | awk '{print $1}' || printf 0)"
  backups_bytes="$(du -sb /backups 2>/dev/null | awk '{print $1}' || printf 0)"
  exports_bytes="$(du -sb /exports 2>/dev/null | awk '{print $1}' || printf 0)"

  cat >"$tmp" <<EOF
# HELP chronicle_release_info Immutable Chronicle release currently observed.
# TYPE chronicle_release_info gauge
chronicle_release_info{version="$(escape_label "$RELEASE_VERSION")"} 1
# HELP chronicle_operational_probe_timestamp_seconds Last completed operational probe.
# TYPE chronicle_operational_probe_timestamp_seconds gauge
chronicle_operational_probe_timestamp_seconds $now
# HELP chronicle_database_up PostgreSQL accepted an authenticated readiness query.
# TYPE chronicle_database_up gauge
chronicle_database_up $db_up
# HELP chronicle_web_up Caddy health is reachable inside the Compose network.
# TYPE chronicle_web_up gauge
chronicle_web_up $web_up
# HELP chronicle_public_probe_success Configured participant endpoint health probe result.
# TYPE chronicle_public_probe_success gauge
chronicle_public_probe_success $public_up
# HELP chronicle_logs_pipeline_up VictoriaLogs accepted a health probe.
# TYPE chronicle_logs_pipeline_up gauge
chronicle_logs_pipeline_up $logs_up
# HELP chronicle_postgres_database_bytes Current Chronicle database size.
# TYPE chronicle_postgres_database_bytes gauge
chronicle_postgres_database_bytes ${db_size:-0}
# HELP chronicle_postgres_connections Current connections to the Chronicle database.
# TYPE chronicle_postgres_connections gauge
chronicle_postgres_connections ${connections:-0}
# HELP chronicle_postgres_max_connections Configured PostgreSQL connection ceiling.
# TYPE chronicle_postgres_max_connections gauge
chronicle_postgres_max_connections ${max_connections:-0}
# HELP chronicle_postgres_transactions_total PostgreSQL transaction outcomes.
# TYPE chronicle_postgres_transactions_total counter
chronicle_postgres_transactions_total{outcome="commit"} ${commits:-0}
chronicle_postgres_transactions_total{outcome="rollback"} ${rollbacks:-0}
# HELP chronicle_postgres_deadlocks_total PostgreSQL deadlocks for the Chronicle database.
# TYPE chronicle_postgres_deadlocks_total counter
chronicle_postgres_deadlocks_total ${deadlocks:-0}
# HELP chronicle_flyway_schema_version Latest successful numeric Flyway migration.
# TYPE chronicle_flyway_schema_version gauge
chronicle_flyway_schema_version ${flyway:-0}
# HELP chronicle_tde_healthy Active pg_tde key, default table access method, and application table coverage.
# TYPE chronicle_tde_healthy gauge
chronicle_tde_healthy $tde_healthy
# HELP chronicle_tde_expected Whether encryption at rest is enabled for this deployment.
# TYPE chronicle_tde_expected gauge
chronicle_tde_expected $tde_expected
# HELP chronicle_backup_latest_success_timestamp_seconds Latest local backup modification time.
# TYPE chronicle_backup_latest_success_timestamp_seconds gauge
chronicle_backup_latest_success_timestamp_seconds $backup_epoch
# HELP chronicle_backups_expected Whether the selected deployment declares scheduled backups.
# TYPE chronicle_backups_expected gauge
chronicle_backups_expected $backups_expected
# HELP chronicle_backup_latest_verified Latest local backup passes gzip verification.
# TYPE chronicle_backup_latest_verified gauge
chronicle_backup_latest_verified $backup_valid
# HELP chronicle_backup_storage_bytes Local backup storage currently used.
# TYPE chronicle_backup_storage_bytes gauge
chronicle_backup_storage_bytes ${backups_bytes:-0}
# HELP chronicle_export_storage_bytes Retained asynchronous export storage currently used.
# TYPE chronicle_export_storage_bytes gauge
chronicle_export_storage_bytes ${exports_bytes:-0}
# HELP chronicle_certificate_expiry_timestamp_seconds Latest mounted TLS certificate expiry.
# TYPE chronicle_certificate_expiry_timestamp_seconds gauge
chronicle_certificate_expiry_timestamp_seconds $cert_expiry
# HELP chronicle_observability_storage_bytes Local observability data currently retained.
# TYPE chronicle_observability_storage_bytes gauge
chronicle_observability_storage_bytes{store="metrics"} ${metrics_bytes:-0}
chronicle_observability_storage_bytes{store="logs"} ${logs_bytes:-0}
# HELP chronicle_observability_storage_budget_bytes Configured local observability budget.
# TYPE chronicle_observability_storage_budget_bytes gauge
chronicle_observability_storage_budget_bytes{store="metrics"} ${METRICS_DISK_BUDGET_BYTES}
chronicle_observability_storage_budget_bytes{store="logs"} ${LOGS_DISK_BUDGET_BYTES}
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" /metrics/operational.prom
}

while true; do
  collect || true
  sleep "$PROBE_INTERVAL_SECONDS"
done
