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
: "${PUBLIC_TLS_URL:=https://${DOMAIN}}"
: "${PUBLIC_CA_FILE:=}"
: "${LOGS_HEALTH_URL:=http://victorialogs:9428/health}"
: "${COMPOSE_FILE_SELECTION:=}"
: "${ENABLE_ENCRYPTION:=true}"
: "${METRICS_DISK_BUDGET_BYTES:=5368709120}"
: "${LOGS_DISK_BUDGET_BYTES:=5368709120}"
[[ -n "$PUBLIC_HEALTH_URL" ]] || PUBLIC_HEALTH_URL="${CHRONICLE_PUBLIC_BASE_URL:-$PUBLIC_TLS_URL}/health"
read -r INTERNAL_TLS_URL INTERNAL_CONNECT < <(python3 - <<'PY_INTERNAL'
from chronicle_ops.common import authority, dashboard_origin
import os
from urllib.parse import urlsplit
origin = dashboard_origin(os.environ)
parsed = urlsplit(origin)
print(origin, authority(parsed.hostname, parsed.port or 443) + ':web:8081')
PY_INTERNAL
)
: "${INTERNAL_HEALTH_URL:=$INTERNAL_TLS_URL/health}"

[[ "$PROBE_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || exit 64
(( PROBE_INTERVAL_SECONDS <= 300 )) || exit 64
mkdir -p /metrics
umask 077
# shellcheck source=selfhost/monitoring/record-operation.sh
source /monitoring/record-operation.sh
logs_probe_category=""

escape_label() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/[[:cntrl:]]//g'
}

file_epoch() {
  stat -c '%Y' "$1" 2>/dev/null || printf '0'
}

certificate_expiry() {
  local expiry
  expiry="$(openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
  if [[ -n "$expiry" ]]; then
    date -d "$expiry" +%s 2>/dev/null || printf 0
  else
    printf 0
  fi
}

public_tls_expiry() {
  if [[ "$1" != https://* || "$DOMAIN" == unknown ]] || ! command -v timeout >/dev/null 2>&1 ||
      ! command -v openssl >/dev/null 2>&1; then
    printf 0
    return
  fi
  local tls_authority tls_target tls_server_name
  local -a tls_sni_args=() tls_trust_args=()
  tls_authority="${1#https://}"
  tls_authority="${tls_authority%%/*}"
  tls_authority="${tls_authority%%\?*}"
  tls_authority="${tls_authority%%#*}"
  tls_server_name="$tls_authority"
  case "$tls_authority" in
    \[*\])
      tls_target="${tls_authority}:443"
      tls_server_name="${tls_authority#\[}"
      tls_server_name="${tls_server_name%%\]*}"
      ;;
    \[*\]:*)
      tls_target="$tls_authority"
      tls_server_name="${tls_authority#\[}"
      tls_server_name="${tls_server_name%%\]*}"
      ;;
    *:*)
      tls_target="$tls_authority"
      tls_server_name="${tls_authority%%:*}"
      ;;
    *) tls_target="${tls_authority}:443" ;;
  esac
  if [[ "$tls_server_name" == *:* || "$tls_server_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    tls_sni_args=(-noservername -verify_ip "$tls_server_name")
  else
    tls_sni_args=(-servername "$tls_server_name" -verify_hostname "$tls_server_name")
  fi
  [[ -z "${2:-}" ]] || tls_trust_args=(-partial_chain -CAfile "$2")
  tls_target="${3:-$tls_target}"
  local served
  served=$(timeout 8 openssl s_client -verify_return_error -connect "$tls_target" "${tls_sni_args[@]}" "${tls_trust_args[@]}" </dev/null 2>/dev/null) || { printf 0; return; }
  printf '%s\n' "$served" | certificate_expiry
}

collect() {
  local now tmp db_up=0 web_up=0 public_up=0 logs_up=0 cert_expiry=0 internal_cert_expiry=0 backup_epoch=0 backup_valid=0 backups_expected=0
  local db_size=0 connections=0 max_connections=0 commits=0 rollbacks=0 deadlocks=0 flyway=0 tde_expected=0 tde_healthy=0
  local metrics_bytes=0 logs_bytes=0 backups_bytes=0 exports_bytes=0
  tmp="/metrics/.operational.prom.$$"
  [[ "$ENABLE_ENCRYPTION" == true ]] && tde_expected=1

  local database_stats
  export PGPASSWORD="$POSTGRES_PASSWORD" PGCONNECT_TIMEOUT=5 PGOPTIONS='-c statement_timeout=5000'
  if pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t 5 >/dev/null 2>&1 &&
      database_stats="$(psql -X -qAt -v ON_ERROR_STOP=1 -F '|' -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT pg_database_size(current_database()),numbackends,current_setting('max_connections')::integer,xact_commit,xact_rollback,deadlocks FROM pg_stat_database WHERE datname=current_database()" 2>/dev/null)"; then
    db_up=1
    IFS='|' read -r db_size connections max_connections commits rollbacks deadlocks <<<"$database_stats"
    flyway="$(psql -X -qAt -v ON_ERROR_STOP=1 -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
      -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
      "SELECT COALESCE(MAX(CASE WHEN version ~ '^[0-9]+$' THEN version::integer END),0) FROM flyway_schema_history WHERE success" 2>/dev/null || printf 0)"
    if [[ $tde_expected -eq 1 ]] && psql -X -qAt -v ON_ERROR_STOP=1 -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
      -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
      "SELECT CASE WHEN current_setting('default_table_access_method')='tde_heap' AND (SELECT key_name FROM pg_tde_key_info()) IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_am a ON a.oid=c.relam WHERE n.nspname='public' AND c.relkind='r' AND a.amname<>'tde_heap') THEN 1 ELSE 0 END" 2>/dev/null | grep -qx 1; then
      tde_healthy=1
    fi
  fi
  unset PGPASSWORD PGCONNECT_TIMEOUT PGOPTIONS

  local internal_ca
  internal_ca="$(python3 -c 'from chronicle_ops.common import dashboard_ca; print(dashboard_ca("/tls"))')"
  local public_ca="$PUBLIC_CA_FILE"
  local -a public_trust=()
  [[ "$COMPOSE_FILE_SELECTION" != *overlays/mode-local-https.yml* ]] || public_ca=/tls/local-ca.crt
  [[ -z "$public_ca" ]] || public_trust=(--cacert "$public_ca")
  if command -v curl >/dev/null 2>&1; then
    [[ "$(curl --connect-to "$INTERNAL_CONNECT" --cacert "$internal_ca" -sS --max-time 8 -o /dev/null -w '%{http_code}' "$INTERNAL_HEALTH_URL" 2>/dev/null)" == 204 ]] && web_up=1 || true
    [[ "$(curl "${public_trust[@]}" -sS --max-time 10 -o /dev/null -w '%{http_code}' "$PUBLIC_HEALTH_URL" 2>/dev/null)" == 204 ]] && public_up=1 || true
    if [[ -n "$logs_probe_category" ]] && curl -fsS --max-time 8 "$LOGS_HEALTH_URL" >/dev/null 2>&1 &&
        curl -fsS --max-time 8 "${LOGS_HEALTH_URL%/health}/select/logsql/query?query=failure_category%3A${logs_probe_category}" |
        grep -Fq "$logs_probe_category"; then
      logs_up=1
    fi
    local logs_token
    if logs_token="$(openssl rand -hex 8)"; then
      logs_probe_category="probe_${logs_token}"
      record_event logs-probe success "$logs_probe_category"
    else
      logs_probe_category=""
    fi
  fi

  cert_expiry="$(public_tls_expiry "$PUBLIC_TLS_URL" "$public_ca")"
  internal_cert_expiry="$(public_tls_expiry "$INTERNAL_TLS_URL" "$internal_ca" web:8081)"

  [[ "$COMPOSE_FILE_SELECTION" == *overlays/backups.yml* ]] && backups_expected=1
  local latest_backup=""
  if [[ -f "/backups/last/$POSTGRES_DB-verified.json" ]]; then
    latest_backup="$(python3 - "$POSTGRES_DB" <<'PY_BACKUP'
from dump import BACKUP_MAX_AGE_SECONDS, backup_marker, verified_backup
import json
from pathlib import Path
import sys
import time

def file_identity(path):
    stat = path.stat()
    return [stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns]

cache = Path('/metrics/.backup-verification.json')
try:
    marker = backup_marker('/backups', sys.argv[1])
    marker_text = marker.read_text()
    try:
        previous = json.loads(cache.read_text())
        path = Path(previous['path'])
        unchanged = previous['marker'] == marker_text and previous['identity'] == file_identity(path)
    except (OSError, ValueError, KeyError, TypeError):
        unchanged = False
    if unchanged:
        if not 0 <= time.time() - previous['verified_at'] <= BACKUP_MAX_AGE_SECONDS:
            raise ValueError('stale verified backup')
    else:
        path, data = verified_backup('/backups', sys.argv[1])
        cache.write_text(json.dumps(dict(path=str(path), marker=marker_text, verified_at=data['verified_at'],
                                        identity=file_identity(path))))
    print(path)
except (OSError, ValueError, KeyError, TypeError):
    pass
PY_BACKUP
)"
  fi
  if [[ -n "$latest_backup" && -s "$latest_backup" ]]; then
    backup_epoch="$(file_epoch "$latest_backup")"
    backup_valid=1
  fi
  metrics_bytes="$(du -sb /observability-data/metrics 2>/dev/null | awk '{print $1}' || printf 0)"
  logs_bytes="$(du -sb /observability-data/logs 2>/dev/null | awk '{print $1}' || printf 0)"
  backups_bytes="$(du -sb /backups 2>/dev/null | awk '{print $1}' || printf 0)"
  exports_bytes="$(du -sb /exports 2>/dev/null | awk '{print $1}' || printf 0)"

  now="$(date +%s)"
  cat >"$tmp" <<EOF
# HELP chronicle_release_info Immutable Chronicle release currently observed.
# TYPE chronicle_release_info gauge
chronicle_release_info{version="$(escape_label "$RELEASE_VERSION")"} 1
# HELP chronicle_operational_probe_timestamp_seconds Last completed operational probe.
# TYPE chronicle_operational_probe_timestamp_seconds gauge
chronicle_operational_probe_timestamp_seconds $now
# HELP chronicle_operational_probe_interval_seconds Configured delay between operational collections.
# TYPE chronicle_operational_probe_interval_seconds gauge
chronicle_operational_probe_interval_seconds $PROBE_INTERVAL_SECONDS
# HELP chronicle_database_up PostgreSQL accepted an authenticated readiness query.
# TYPE chronicle_database_up gauge
chronicle_database_up $db_up
# HELP chronicle_web_up Caddy health is reachable inside the Compose network.
# TYPE chronicle_web_up gauge
chronicle_web_up $web_up
# HELP chronicle_public_probe_success Configured participant endpoint health probe result.
# TYPE chronicle_public_probe_success gauge
chronicle_public_probe_success $public_up
# HELP chronicle_logs_pipeline_up Previous probe event traversed Fluent Bit to healthy VictoriaLogs.
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
# HELP chronicle_backup_latest_verified Latest local backup matches its verified marker and file identity.
# TYPE chronicle_backup_latest_verified gauge
chronicle_backup_latest_verified $backup_valid
# HELP chronicle_backup_storage_bytes Local backup storage currently used.
# TYPE chronicle_backup_storage_bytes gauge
chronicle_backup_storage_bytes ${backups_bytes:-0}
# HELP chronicle_export_storage_bytes Retained asynchronous export storage currently used.
# TYPE chronicle_export_storage_bytes gauge
chronicle_export_storage_bytes ${exports_bytes:-0}
# HELP chronicle_certificate_expiry_timestamp_seconds Expiry of the certificate served by the public HTTPS origin.
# TYPE chronicle_certificate_expiry_timestamp_seconds gauge
chronicle_certificate_expiry_timestamp_seconds $cert_expiry
# HELP chronicle_internal_certificate_expiry_timestamp_seconds Expiry of the internal dashboard listener certificate.
# TYPE chronicle_internal_certificate_expiry_timestamp_seconds gauge
chronicle_internal_certificate_expiry_timestamp_seconds $internal_cert_expiry
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
