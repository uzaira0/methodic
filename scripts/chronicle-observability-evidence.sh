#!/usr/bin/env bash
# Collect static observability fallback evidence without querying private data.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="${CHRONICLE_OBSERVABILITY_EVIDENCE_DIR:-/tmp/chronicle-observability-evidence}"
GRAFANA_DIR="$ROOT_DIR/k8s/observability/grafana-lite"
VICTORIA_DIR="$ROOT_DIR/k8s/observability/victoria-lite"
SIEM_DIR="$ROOT_DIR/k8s/observability/siem-forwarder"
SIEM_EVIDENCE_FILE="${CHRONICLE_OBSERVABILITY_REDACTED_SIEM_EVIDENCE:-}"
REQUIRE_SIEM_EVIDENCE=0
FORBIDDEN_EVIDENCE_PLACEHOLDER_PATTERN='(^|[^[:alnum:]])(TODO|TBD|CHANGEME|CHANGE_ME|REPLACE_ME|REPLACE_WITH|INSERT_|YOUR_|EXAMPLE_|PLACEHOLDER|LOREM IPSUM)([^[:alnum:]]|$)|/path/to/|example\.com'
FORBIDDEN_EVIDENCE_SECRET_PATTERN='-----BEGIN[[:space:]]+([A-Z]+[[:space:]]+)?PRIVATE[[:space:]]+KEY-----|authorization[[:space:]]*[:=][[:space:]]*[^[:space:]]+|bearer[[:space:]]+[A-Za-z0-9._~+/=-]+|api[_-]?key[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._~+/=-]{8,}|token[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._~+/=-]{8,}|password[[:space:]]*[:=][[:space:]]*[^[:space:]]+|client[_-]?secret[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._~+/=-]{8,}|client-key-data|client-certificate-data|certificate-authority-data'

usage() {
  cat <<'EOF'
Usage: scripts/chronicle-observability-evidence.sh [options]

Collects static, redacted observability fallback evidence:
  - canonical checkout proof
  - rendered VictoriaMetrics/VictoriaLogs/Grafana/SIEM manifests
  - observability guardrail output
  - Grafana alert rule inventory
  - Grafana contact point and notification policy inventory
  - alert coverage matrix separating local fallback coverage from external requirements
  - log/SIEM coverage matrix separating local VictoriaLogs fallback proof from operator SIEM delivery requirements
  - dashboard query inventory
  - SIEM forwarder redaction inventory and sanitized sample event
  - artifact SHA-256 manifest

Options:
  --report-dir DIR      Evidence output directory.
  --siem-evidence FILE  Optional redacted SIEM handoff evidence attachment to validate and checksum.
  --require-siem-evidence
                        Fail if no --siem-evidence/CHRONICLE_OBSERVABILITY_REDACTED_SIEM_EVIDENCE is provided.
  -h, --help            Show this help.

The script does not query live metrics/logs and does not read Kubernetes Secret
values. Strict cutover still requires CHRONICLE_SIEM_EVIDENCE and
CHRONICLE_ALERT_ROUTING_EVIDENCE through the operator's deployment approval process.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-dir)
      REPORT_DIR="${2:?--report-dir requires a value}"
      shift 2
      ;;
    --siem-evidence)
      SIEM_EVIDENCE_FILE="${2:?--siem-evidence requires a value}"
      shift 2
      ;;
    --require-siem-evidence)
      REQUIRE_SIEM_EVIDENCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$REPORT_DIR"
SUMMARY="$REPORT_DIR/summary.tsv"
: > "$SUMMARY"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

record() {
  printf '%s\t%s\t%s\n' "$(timestamp)" "$1" "$2" | tee -a "$SUMMARY"
}

run_step() {
  local name="$1"
  shift
  local logfile="$REPORT_DIR/${name//[^A-Za-z0-9_.-]/_}.log"
  record "$name" "start"
  if "$@" >"$logfile" 2>&1; then
    record "$name" "pass"
  else
    local status=$?
    record "$name" "fail status=$status log=$logfile"
    cat "$logfile" >&2
    exit "$status"
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

evidence_contains_pattern() {
  local path="$1"
  local pattern="$2"
  grep -Eiq -- "$pattern" "$path"
}

require_evidence_pattern() {
  local path="$1"
  local pattern="$2"
  local description="$3"
  if ! evidence_contains_pattern "$path" "$pattern"; then
    echo "redacted SIEM evidence must include $description" >&2
    return 1
  fi
}

validate_redacted_siem_evidence_attachment() {
  local output="$REPORT_DIR/redacted-siem-evidence.txt"

  if [ -z "$SIEM_EVIDENCE_FILE" ]; then
    if [ "$REQUIRE_SIEM_EVIDENCE" -eq 1 ]; then
      echo "redacted SIEM evidence is required but no file was provided" >&2
      return 1
    fi
    {
      printf 'status=not_provided\n'
      printf 'note=%s\n' "Static fallback/redaction evidence only. Strict cutover still requires CHRONICLE_SIEM_EVIDENCE and CHRONICLE_ALERT_ROUTING_EVIDENCE."
    } > "$output"
    return 0
  fi

  if [ -L "$SIEM_EVIDENCE_FILE" ]; then
    echo "redacted SIEM evidence must not be a symlink: $SIEM_EVIDENCE_FILE" >&2
    return 1
  fi
  if [ ! -f "$SIEM_EVIDENCE_FILE" ] || [ ! -r "$SIEM_EVIDENCE_FILE" ]; then
    echo "redacted SIEM evidence is not a readable file: $SIEM_EVIDENCE_FILE" >&2
    return 1
  fi
  if evidence_contains_pattern "$SIEM_EVIDENCE_FILE" "$FORBIDDEN_EVIDENCE_PLACEHOLDER_PATTERN"; then
    echo "redacted SIEM evidence contains unresolved placeholder text" >&2
    return 1
  fi
  if evidence_contains_pattern "$SIEM_EVIDENCE_FILE" "$FORBIDDEN_EVIDENCE_SECRET_PATTERN"; then
    echo "redacted SIEM evidence appears to contain raw credential or private key material" >&2
    return 1
  fi

  require_evidence_pattern "$SIEM_EVIDENCE_FILE" 'Mode:|operator SIEM|local fallback|selected logging mode' "the selected logging mode"
  require_evidence_pattern "$SIEM_EVIDENCE_FILE" 'Endpoint or fallback store|SIEM endpoint|intake|fallback store' "the endpoint or fallback store"
  require_evidence_pattern "$SIEM_EVIDENCE_FILE" 'Transport/auth|transport/authentication|transport and authentication|TLS' "transport/authentication evidence"
  require_evidence_pattern "$SIEM_EVIDENCE_FILE" 'Retention owner|retention period|retention' "retention ownership or period"
  require_evidence_pattern "$SIEM_EVIDENCE_FILE" 'redaction_contract|Redaction contract marker|forbidden_fields_removed|Forbidden-field validation' "redaction-marker or forbidden-field validation evidence"
  require_evidence_pattern "$SIEM_EVIDENCE_FILE" 'correlation/request ID preservation|correlation_id|request_id' "correlation/request ID preservation proof"
  require_evidence_pattern "$SIEM_EVIDENCE_FILE" 'Sanitized test-event delivery|sanitized test-event delivery|test-event delivery|accepted event|approved exception' "sanitized test-event delivery proof or approved exception"
  require_evidence_pattern "$SIEM_EVIDENCE_FILE" 'Raw network identifier decision|raw network identifier|raw-network|client IP|User-Agent' "raw network identifier handling"
  require_evidence_pattern "$SIEM_EVIDENCE_FILE" 'Alert routing|alert routing|alert-route|alert-routing|approved alert' "alert routing or exception"
  require_evidence_pattern "$SIEM_EVIDENCE_FILE" 'Log/SIEM coverage matrix|log-siem-coverage-matrix' "log/SIEM coverage matrix evidence"
  require_evidence_pattern "$SIEM_EVIDENCE_FILE" 'owner|Owner|review date|Review date|stop condition|Stop condition' "owner, review, or stop-condition metadata"

  {
    printf 'status=attached_redacted_evidence\n'
    printf 'source_path=%s\n' "$SIEM_EVIDENCE_FILE"
    printf 'source_sha256=%s\n' "$(sha256_file "$SIEM_EVIDENCE_FILE")"
    printf 'copied_content=false\n'
    printf 'strict_cutover_note=%s\n' "This attachment is validated and checksummed for the static bundle, but strict cutover still uses CHRONICLE_SIEM_EVIDENCE through the operator's deployment approval process."
  } > "$output"
}

render_overlay() {
  local overlay="$1"
  local output="$2"
  if command -v kubectl >/dev/null 2>&1; then
    kubectl kustomize "$overlay" > "$output"
  elif command -v kustomize >/dev/null 2>&1; then
    kustomize build "$overlay" > "$output"
  else
    echo "kubectl or kustomize is required to render observability overlays" >&2
    return 127
  fi
}

render_observability_manifests() {
  render_overlay "$VICTORIA_DIR" "$REPORT_DIR/victoria-lite-rendered.yaml"
  render_overlay "$GRAFANA_DIR" "$REPORT_DIR/grafana-lite-rendered.yaml"
  render_overlay "$SIEM_DIR" "$REPORT_DIR/siem-forwarder-rendered.yaml"
}

write_alert_inventory() {
  python3 - "$ROOT_DIR" "$REPORT_DIR" <<'PY'
import json
import pathlib
import re
import sys

import yaml

root = pathlib.Path(sys.argv[1])
report = pathlib.Path(sys.argv[2])
alert_dir = root / "k8s/observability/grafana-lite/config/alerting"
dashboard_dir = root / "k8s/observability/grafana-lite/config/dashboards"

forbidden = re.compile(
    r"participantId|participant_id|sourceDevice|source_device|deviceId|device_id|"
    r"Bearer\s+|Authorization:|api[_-]?key[=:]|token[=:]|password[=:]|"
    r"client[_-]?secret[=:]|requestBody|responseBody|rawPayload|stackTrace",
    re.IGNORECASE,
)

contactpoints = yaml.safe_load((alert_dir / "contactpoints.yml").read_text(encoding="utf-8"))
policies = yaml.safe_load((alert_dir / "notification-policies.yml").read_text(encoding="utf-8"))
rules = yaml.safe_load((alert_dir / "rules.yml").read_text(encoding="utf-8"))

contact_rows = ["name\treceiver_uid\ttype\turl_class\tplaceholder"]
for contact in contactpoints.get("contactPoints", []):
    name = contact.get("name", "")
    for receiver in contact.get("receivers", []):
        settings = receiver.get("settings", {})
        url = settings.get("url", "")
        if url == "http://127.0.0.1:9/chronicle-alert-placeholder":
            url_class = "dead-local-placeholder"
            placeholder = "true"
        elif url.startswith("http://") or url.startswith("https://"):
            url_class = "configured-url-redacted"
            placeholder = "false"
        else:
            url_class = "not-url-or-empty"
            placeholder = "false"
        contact_rows.append(
            "\t".join([name, str(receiver.get("uid", "")), str(receiver.get("type", "")), url_class, placeholder])
        )

policy_rows = ["receiver\troute_count\tcritical_route\tgroup_by\trepeat_interval"]
for policy in policies.get("policies", []):
    routes = policy.get("routes", [])
    critical_route = any(
        matcher == ["severity", "=", "critical"]
        for route in routes
        for matcher in route.get("object_matchers", [])
    )
    policy_rows.append(
        "\t".join([
            str(policy.get("receiver", "")),
            str(len(routes)),
            str(critical_route).lower(),
            ",".join(policy.get("group_by", [])),
            str(policy.get("repeat_interval", "")),
        ])
    )

alert_rows = ["uid\ttitle\tseverity\tservice\tno_data\texec_error\tfor\trunbook\tquery_refs"]
blockers = []
for group in rules.get("groups", []):
    for rule in group.get("rules", []):
        uid = str(rule.get("uid", ""))
        text = repr(rule)
        if forbidden.search(text):
            blockers.append(f"forbidden alert text pattern in {uid}")
        labels = rule.get("labels", {})
        annotations = rule.get("annotations", {})
        refs = ",".join(str(datum.get("refId", "")) for datum in rule.get("data", []))
        alert_rows.append(
            "\t".join([
                uid,
                str(rule.get("title", "")),
                str(labels.get("severity", "")),
                str(labels.get("service", "")),
                str(rule.get("noDataState", "")),
                str(rule.get("execErrState", "")),
                str(rule.get("for", "")),
                str(annotations.get("runbook_url", "")),
                refs,
            ])
        )

dashboard_rows = ["file\tuid\ttitle\tpanel_count\tquery_count\tforbidden_pattern"]
for path in sorted(dashboard_dir.glob("*.json")):
    data = json.loads(path.read_text(encoding="utf-8"))
    panels = data.get("panels", [])
    query_count = 0
    forbidden_hit = False
    for panel in panels:
        for target in panel.get("targets", []):
            query_count += 1
            if forbidden.search(repr(target)):
                forbidden_hit = True
    if forbidden_hit:
        blockers.append(f"forbidden dashboard query pattern in {path.name}")
    dashboard_rows.append(
        "\t".join([
            path.name,
            str(data.get("uid", "")),
            str(data.get("title", "")),
            str(len(panels)),
            str(query_count),
            str(forbidden_hit).lower(),
        ])
    )

(report / "alert-contactpoints.tsv").write_text("\n".join(contact_rows) + "\n", encoding="utf-8")
(report / "alert-notification-policies.tsv").write_text("\n".join(policy_rows) + "\n", encoding="utf-8")
(report / "alert-rules.tsv").write_text("\n".join(alert_rows) + "\n", encoding="utf-8")
(report / "dashboard-query-inventory.tsv").write_text("\n".join(dashboard_rows) + "\n", encoding="utf-8")
(report / "privacy-blockers.txt").write_text("\n".join(blockers) + ("\n" if blockers else ""), encoding="utf-8")
if blockers:
    raise SystemExit("\n".join(blockers))
PY
}

write_alert_coverage_matrix() {
  cat > "$REPORT_DIR/alert-coverage-matrix.tsv" <<'EOF'
signal	source	artifact	coverage_status	cutover_requirement
backend-availability	Grafana fallback rule	alert-rules.tsv	covered-by-local-fallback	keep VictoriaMetrics backend scrape and alert provisioning evidence passing
database-pool-pressure	Grafana fallback rule	alert-rules.tsv	covered-by-local-fallback	keep backend Hikari metrics scrape and alert provisioning evidence passing
backend-5xx-errors	Grafana fallback rule	alert-rules.tsv	covered-by-local-fallback	route-template metrics must stay sanitized and backend error evidence remains separate
enrollment-failures	Grafana fallback rule	alert-rules.tsv	covered-by-local-fallback	route-template metrics must stay sanitized; distinguish expected bad participant/signature from server failure during incident review
backup-freshness	Grafana fallback rule	alert-rules.tsv	covered-by-local-fallback	runtime RPO proof still requires CHRONICLE_RPO_EVIDENCE
mobile-upload-failures	Grafana fallback rule	alert-rules.tsv	covered-by-local-fallback	route-template metrics must stay sanitized and mobile evidence remains separate
alert-notification-delivery	Grafana contact point	CHRONICLE_ALERT_ROUTING_EVIDENCE	required-external	test-alert delivery proof or approved local exception before cutover
severity-escalation-routing	operator or approved operator path	CHRONICLE_ALERT_ROUTING_EVIDENCE	required-external	P0/P1/critical escalation, owner, review date, and stop condition
node-readiness	operator monitoring or private exporter	CHRONICLE_SIEM_EVIDENCE|required-private-exporter	required-external	operator monitoring evidence or private kube-state/node exporter scrape with guardrails
pod-restart-oom	operator monitoring or private exporter	CHRONICLE_SIEM_EVIDENCE|required-private-exporter	required-external	operator monitoring evidence or private kube-state/node exporter scrape with guardrails
host-disk-pressure	operator monitoring or private exporter	CHRONICLE_SIEM_EVIDENCE|required-private-exporter	required-external	operator monitoring evidence or private node exporter scrape with guardrails
waf-rate-limit	operator edge/WAF/SIEM	CHRONICLE_SIEM_EVIDENCE	required-external	operator WAF/rate-limit event delivery or approved exception
certificate-expiry	operator edge monitoring	CHRONICLE_EDGE_EVIDENCE|required-external	required-external	operator-owned TLS/certificate monitoring evidence or approved exception
EOF
}

write_log_siem_coverage_matrix() {
  cat > "$REPORT_DIR/log-siem-coverage-matrix.tsv" <<'EOF'
signal	source	artifact	coverage_status	cutover_requirement
local-victorialogs-retention	VictoriaLogs fallback	victoria-lite-rendered.yaml	covered-by-local-fallback	private seven-day retention only; not institutional SIEM evidence
local-log-ingestion	Fluent Bit local fallback	victoria-lite-rendered.yaml|docker/siem/victorialogs-fluent-bit.conf	covered-by-local-fallback	private ClusterIP/no-public-route evidence and bounded retention must stay passing
local-dashboard-log-visibility	Grafana fallback	grafana-lite-rendered.yaml|dashboard-query-inventory.tsv	covered-by-local-fallback	operator-only/private access and dashboard forbidden-field checks must stay passing
siem-forwarder-redaction	operator SIEM forwarder package	siem-forwarder-field-removals.tsv|siem-forwarder-redaction-summary.tsv|siem-sanitized-sample-event.json|siem-sample-forbidden-findings.txt	covered-by-local-bundle	strict evidence must attach forbidden-field validation and redaction markers
siem-forwarder-disabled-default	operator SIEM forwarder package	siem-forwarder-rendered.yaml	covered-by-local-bundle	deployment remains replicas=0 until endpoint/auth/network approval exists
siem-endpoint-delivery	operator SIEM/intake	CHRONICLE_SIEM_EVIDENCE	required-strict-evidence	operator endpoint/ticket and test sanitized event delivery proof or approved exception
siem-auth-secret-store	operator or approved secret store	CHRONICLE_SIEM_EVIDENCE	required-strict-evidence	secret-store key names/sync proof without raw credentials
correlation-id-preservation	operator SIEM/intake or approved fallback	CHRONICLE_SIEM_EVIDENCE|siem-sanitized-sample-event.json	required-strict-evidence	correlation_id/request_id must survive gateway/backend/forwarder delivery or exception approval
siem-test-event-delivery	operator SIEM/intake or approved fallback	CHRONICLE_SIEM_EVIDENCE	required-strict-evidence	sanitized test event delivery receipt/accepted event ID or approved exception
raw-network-decision	operator security decision	CHRONICLE_SIEM_EVIDENCE	required-strict-evidence	raw IP/User-Agent approval or explicit redacted-only decision
siem-retention-owner	operator SIEM or approved fallback	CHRONICLE_SIEM_EVIDENCE	required-strict-evidence	retention owner/period/export/deletion handling
local-fallback-exception	Chronicle local fallback	CHRONICLE_SIEM_EVIDENCE	required-strict-evidence	owner approval expiry stop condition private exposure bounded retention backup/retention handling
alert-routing-linkage	operator alert route or exception	CHRONICLE_ALERT_ROUTING_EVIDENCE|alert-coverage-matrix.tsv|required-strict-evidence	required-strict-evidence	test-alert delivery proof or approved exception tied to alert coverage
EOF
}

write_siem_redaction_evidence() {
  python3 - "$ROOT_DIR" "$REPORT_DIR" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
report = pathlib.Path(sys.argv[2])
config_path = root / "k8s/observability/siem-forwarder/config/fluent-bit.conf"
config = config_path.read_text(encoding="utf-8")

remove_fields = []
add_fields = {}
for line in config.splitlines():
    remove_match = re.match(r"\s*Remove\s+([A-Za-z0-9_]+)\s*$", line)
    if remove_match:
        remove_fields.append(remove_match.group(1))
        continue
    add_match = re.match(r"\s*Add\s+([A-Za-z0-9_]+)\s+(.+?)\s*$", line)
    if add_match:
        add_fields[add_match.group(1)] = add_match.group(2)

required_removals = {
    "userId",
    "user_id",
    "resourceId",
    "resource_id",
    "studyId",
    "study_id",
    "participantId",
    "participant_id",
    "sourceDevice",
    "source_device",
    "deviceId",
    "device_id",
    "ipAddress",
    "ip_address",
    "clientIp",
    "client_ip",
    "remoteAddr",
    "forwardedFor",
    "xForwardedFor",
    "userAgent",
    "user_agent",
    "phiFields",
    "errorMessage",
    "exceptionMessage",
    "stackTrace",
    "requestUrl",
    "request_url",
    "callbackUrl",
    "callback_url",
    "fullUrl",
    "full_url",
    "requestBody",
    "request_body",
    "responseBody",
    "response_body",
    "payload",
    "rawPayload",
    "raw_payload",
    "headers",
    "authorization",
    "cookie",
    "setCookie",
    "accessToken",
    "access_token",
    "refreshToken",
    "refresh_token",
    "oidcCode",
    "oidc_code",
    "jwt",
    "sessionId",
    "session_id",
    "apiKey",
    "api_key",
    "mobileSigningKey",
    "mobile_signing_key",
}
missing = sorted(required_removals - set(remove_fields))
if missing:
    raise SystemExit("SIEM forwarder missing required removals: " + ", ".join(missing))

sample = {
    "timestamp": "2026-07-06T00:00:00Z",
    "event_type": "mobile.upload",
    "outcome": "failed",
    "route_template": "/chronicle/v4/study/{studyId}/participant/{participantId}/upload",
    "correlation_id": "example-correlation-id",
    "request_id": "example-request-id",
    "participant_ref": "participant:hash:example",
    "device_ref": "device:hash:example",
    "status_code": 401,
    "failure_class": "invalid_signature",
}
for field in remove_fields:
    sample[field] = "FORBIDDEN_SAMPLE_VALUE"

for field in remove_fields:
    sample.pop(field, None)
sample.update(add_fields)

for required_marker in [
    ("redaction_contract", "chronicle-production-observability-v1"),
    ("forbidden_fields_removed", "true"),
    ("siem_forwarder", "chronicle-siem-forwarder-v1"),
]:
    if sample.get(required_marker[0]) != required_marker[1]:
        raise SystemExit(f"sample missing marker {required_marker[0]}={required_marker[1]}")

forbidden = re.compile(
    r"participantId|participant_id|sourceDevice|source_device|deviceId|device_id|"
    r"userId|user_id|resourceId|resource_id|studyId|study_id|ipAddress|ip_address|"
    r"clientIp|client_ip|remoteAddr|forwardedFor|xForwardedFor|userAgent|user_agent|"
    r"phiFields|errorMessage|exceptionMessage|stackTrace|requestUrl|request_url|"
    r"callbackUrl|callback_url|fullUrl|full_url|requestBody|request_body|"
    r"responseBody|response_body|rawPayload|raw_payload|payload|headers|"
    r"authorization|cookie|setCookie|accessToken|access_token|refreshToken|"
    r"refresh_token|oidcCode|oidc_code|jwt|apiKey|api_key|token|password|secret|"
    r"mobileSigningKey|mobile_signing_key|sessionId|session_id|FORBIDDEN_SAMPLE_VALUE",
    re.IGNORECASE,
)
sample_text = json.dumps(sample, sort_keys=True)
findings = []
for key, value in sample.items():
    joined = f"{key}={value}"
    if forbidden.search(joined) and key not in {"route_template"}:
        findings.append(key)

(report / "siem-forwarder-field-removals.tsv").write_text(
    "field\tstatus\n" + "\n".join(f"{field}\tremoved" for field in remove_fields) + "\n",
    encoding="utf-8",
)
(report / "siem-sanitized-sample-event.json").write_text(
    json.dumps(sample, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
(report / "siem-sample-forbidden-findings.txt").write_text(
    "\n".join(findings) + ("\n" if findings else ""),
    encoding="utf-8",
)
(report / "siem-forwarder-redaction-summary.tsv").write_text(
    "\n".join(
        [
            "key\tvalue",
            f"config\t{config_path.relative_to(root)}",
            f"removed_field_count\t{len(remove_fields)}",
            "sample_contains_redaction_contract\ttrue",
            "sample_contains_forbidden_fields_removed\ttrue",
            f"sample_forbidden_findings\t{len(findings)}",
            "sample_contains_correlation_id\ttrue",
            "sample_contains_request_id\ttrue",
            "strict_cutover_siem_evidence\tCHRONICLE_SIEM_EVIDENCE",
        ]
    )
    + "\n",
    encoding="utf-8",
)
if findings:
    raise SystemExit("sanitized SIEM sample still contains forbidden fields: " + ", ".join(findings))
PY
}

write_manifest() {
  local manifest="$REPORT_DIR/observability-evidence-manifest.txt"
  {
    printf 'date_utc=%s\n' "$(timestamp)"
    printf 'repo=%s\n' "$ROOT_DIR"
    printf 'grafana_alert_rules=%s\n' "k8s/observability/grafana-lite/config/alerting/rules.yml"
    printf 'victoria_retention=%s\n' "7d"
    printf 'routing_status=%s\n' "placeholder-until-CHRONICLE_ALERT_ROUTING_EVIDENCE"
    printf 'strict_cutover_siem_evidence=%s\n' "CHRONICLE_SIEM_EVIDENCE"
    printf 'strict_cutover_alert_routing_evidence=%s\n' "CHRONICLE_ALERT_ROUTING_EVIDENCE"
    printf 'artifact\tsha256\n'
    for artifact in \
      victoria-lite-rendered.yaml \
      grafana-lite-rendered.yaml \
      siem-forwarder-rendered.yaml \
      alert-contactpoints.tsv \
      alert-notification-policies.tsv \
      alert-rules.tsv \
      alert-coverage-matrix.tsv \
      log-siem-coverage-matrix.tsv \
      dashboard-query-inventory.tsv \
      siem-forwarder-field-removals.tsv \
      siem-forwarder-redaction-summary.tsv \
      siem-sanitized-sample-event.json \
      siem-sample-forbidden-findings.txt \
      redacted-siem-evidence.txt \
      privacy-blockers.txt \
      observability-guardrails/observability-guardrails.txt; do
      printf '%s\t%s\n' "$artifact" "$(sha256_file "$REPORT_DIR/$artifact")"
    done
  } > "$manifest"
}

run_step "canonical-preflight-explain" "${REPO_CANONICAL_PREFLIGHT:-repo-canonical-preflight}" --explain
run_step "canonical-preflight" "${REPO_CANONICAL_PREFLIGHT:-repo-canonical-preflight}"
run_step "render-observability-manifests" render_observability_manifests
run_step "observability-guardrails" "$ROOT_DIR/tests/security/observability-guardrails.sh" "$REPORT_DIR/observability-guardrails"
run_step "alert-dashboard-inventory" write_alert_inventory
run_step "alert-coverage-matrix" write_alert_coverage_matrix
run_step "log-siem-coverage-matrix" write_log_siem_coverage_matrix
run_step "siem-redaction-evidence" write_siem_redaction_evidence
run_step "redacted-siem-evidence-attachment" validate_redacted_siem_evidence_attachment
run_step "write-observability-evidence-manifest" write_manifest

record "evidence" "complete report_dir=$REPORT_DIR"
printf 'Chronicle observability evidence complete: %s\n' "$REPORT_DIR"
