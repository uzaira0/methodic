#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'monitoring-config: %s\n' "$*" >&2; exit 1; }

: "${METRICS_USERNAME:=chronicle-metrics}"
: "${METRICS_PASSWORD:?METRICS_PASSWORD is required}"
: "${COMPOSE_PROJECT_NAME:=chronicle-selfhost}"
[[ ${#METRICS_PASSWORD} -ge 32 && ${#METRICS_PASSWORD} -le 1024 ]] ||
  fail "metrics password must contain 32..1024 characters"
[[ "$METRICS_USERNAME" =~ ^[A-Za-z0-9._-]{1,64}$ ]] ||
  fail "metrics username contains unsupported characters"

[[ "$COMPOSE_PROJECT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$ ]] ||
  fail "Compose project name cannot be represented safely in the scrape allowlist"

mkdir -p /monitoring-secrets /monitoring-config /metrics
umask 077
temporary="/monitoring-secrets/.metrics-password.$$"
printf '%s' "$METRICS_PASSWORD" >"$temporary"
mv -f "$temporary" /monitoring-secrets/metrics-password
config_tmp="/monitoring-config/.scrape.yml.$$"
cat >"$config_tmp" <<EOF
global:
  scrape_interval: 15s
  scrape_timeout: 10s

scrape_configs:
  - job_name: chronicle-backend
    metrics_path: /prometheus/
    basic_auth:
      username: ${METRICS_USERNAME}
      password_file: /run/secrets/chronicle-metrics/metrics-password
    static_configs:
      - targets: ["backend:40320"]
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'chronicle_(enrollment_total|upload_total|upload_errors_total|sensor_materialization_runs_total|sensor_materialized_samples_total|sensor_materialization_quarantined_rows_total|sensor_materialization_duration_seconds(_bucket|_count|_sum)?|api_request_duration_seconds(_bucket|_count|_sum)?|api_errors_total|participant_form_access_total|participant_form_submission_total|data_deletion_operations_total|data_deletion_operation_duration_seconds(_bucket|_count|_sum)?|data_deletion_retention_holds_total|data_quality_evaluations_total|data_quality_alerts_total|export_artifact_bytes|export_storage_usable_bytes|export_storage_admission_rejections_total|export_jobs_total|active_requests)'
        action: keep
      - regex: '(study_ref|study_id|participant_id|device_id|user_id|source_ip|client_ip|key_name|key_prefix|instance)'
        action: labeldrop
  - job_name: chronicle-containers
    static_configs:
      - targets: ["cadvisor:8080"]
    metric_relabel_configs:
      - source_labels: [name]
        regex: '/?${COMPOSE_PROJECT_NAME}[-_].*'
        action: keep
  - job_name: chronicle-host
    static_configs:
      - targets: ["cadvisor:8080"]
    metric_relabel_configs:
      - source_labels: [__name__, id]
        separator: ';'
        regex: '(machine_.*;.*|container_(cpu_.*|memory_.*|fs_.*);/)'
        action: keep
  - job_name: chronicle-operational
    metrics_path: /operational.prom
    static_configs:
      - targets: ["metrics-exporter:9090"]
  - job_name: chronicle-log-forwarder
    metrics_path: /api/v1/metrics/prometheus
    static_configs:
      - targets: ["fluent-bit:2020"]
  - job_name: chronicle-operations
    metrics_path: /operations.prom
    static_configs:
      - targets: ["metrics-exporter:9090"]
  - job_name: chronicle-configuration
    metrics_path: /configuration.prom
    static_configs:
      - targets: ["metrics-exporter:9090"]
EOF
chmod 0644 "$config_tmp"
mv -f "$config_tmp" /monitoring-config/scrape.yml
if [[ ! -e /metrics/operations.prom ]]; then
  cat >/metrics/operations.prom <<'EOF'
# HELP chronicle_operator_operation_timestamp_seconds Last completion time of a guarded operator operation.
# TYPE chronicle_operator_operation_timestamp_seconds gauge
EOF
  chmod 0644 /metrics/operations.prom
fi
if [[ ! -e /metrics/operator-events.jsonl ]]; then
  printf '{"failureCategory":"none","operation":"setup","outcome":"success","releaseVersion":"%s","severity":"INFO","timestamp":"%s"}\n' \
    "${RELEASE_VERSION:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /metrics/operator-events.jsonl
  chmod 0644 /metrics/operator-events.jsonl
fi
if [[ ! -e /metrics/configuration.prom ]]; then
  cat >/metrics/configuration.prom <<EOF
# HELP chronicle_configuration_valid Latest configuration guard result.
# TYPE chronicle_configuration_valid gauge
chronicle_configuration_valid 0
# HELP chronicle_configuration_check_timestamp_seconds Latest configuration guard run.
# TYPE chronicle_configuration_check_timestamp_seconds gauge
chronicle_configuration_check_timestamp_seconds $(date +%s)
EOF
  chmod 0644 /metrics/configuration.prom
fi
printf 'monitoring-config: scraper credential installed without printing it\n'
