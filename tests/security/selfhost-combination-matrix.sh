#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SELFHOST_ROOT="${SELFHOST_MATRIX_ROOT:-${ROOT_DIR}/selfhost}"
RUN_PARENT="${SELFHOST_MATRIX_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-matrix}"
DOC="${SELFHOST_ROOT}/docs/DEPLOYMENT-COMPATIBILITY.md"

fail() {
  echo "self-host combination matrix failed: $*" >&2
  exit 1
}

[[ "$SELFHOST_ROOT" == /* ]] || fail "SELFHOST_MATRIX_ROOT must be absolute"
[[ "$RUN_PARENT" == /* ]] || fail "test run parent must be absolute"
case "$RUN_PARENT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
    fail "test run parent must not use a system temporary directory"
    ;;
esac
[[ -f "$DOC" ]] || fail "deployment compatibility document is missing"
[[ -x "${SELFHOST_ROOT}/guard-config.sh" ]] || fail "configuration guard is missing or not executable"
command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is required"

if command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT=(gtimeout)
elif command -v timeout >/dev/null 2>&1; then
  TIMEOUT=(timeout)
else
  fail "GNU timeout or gtimeout is required for bounded Compose rendering"
fi

mapfile -t supported_modes < <(
  find "${SELFHOST_ROOT}/overlays" -maxdepth 1 -type f -name 'mode-*.yml' -exec basename {} \; | LC_ALL=C sort
)
expected_modes=$'mode-behind-proxy-internal.yml\nmode-local-https.yml\nmode-own-tls-internal.yml'
[[ "$(printf '%s\n' "${supported_modes[@]}")" == "$expected_modes" ]] ||
  fail "overlays/ must contain exactly the three documented supported modes"

# profile-id | mode-overlay | encryption | backups
profiles=(
  'proxy-encrypted|mode-behind-proxy-internal.yml|true|true'
  'proxy-plain|mode-behind-proxy-internal.yml|false|true'
  'tls-encrypted|mode-own-tls-internal.yml|true|true'
  'tls-plain|mode-own-tls-internal.yml|false|true'
  'trial-encrypted|mode-local-https.yml|true|true'
  'trial-plain-backed-up|mode-local-https.yml|false|true'
  'trial-plain-no-backup|mode-local-https.yml|false|false'
)

for profile in "${profiles[@]}"; do
  profile_id="${profile%%|*}"
  grep -Fq "\`${profile_id}\`" "$DOC" || fail "documentation omits profile ${profile_id}"
done
grep -Fq '**14 concrete supported combinations**' "$DOC" ||
  fail "documentation does not state the concrete matrix size"

umask 077
/bin/mkdir -p "$RUN_PARENT"
RUN_DIR="$(/usr/bin/mktemp -d "${RUN_PARENT}/run.XXXXXX")"
trap '/bin/rm -rf -- "$RUN_DIR"' EXIT

DEPLOYMENT="${RUN_DIR}/deployment"
/bin/mkdir -p "${DEPLOYMENT}/overlays"
/bin/cp "${SELFHOST_ROOT}/docker-compose.yml" "${DEPLOYMENT}/docker-compose.yml"
for mode in "${supported_modes[@]}"; do
  /bin/cp "${SELFHOST_ROOT}/overlays/${mode}" "${DEPLOYMENT}/overlays/${mode}"
done
/bin/cp "${SELFHOST_ROOT}/overlays/backups.yml" "${DEPLOYMENT}/overlays/backups.yml"
/bin/cp "${SELFHOST_ROOT}/overlays/monitoring.yml" "${DEPLOYMENT}/overlays/monitoring.yml"

render_env() {
  local output="$1" compose_file="$2" encryption="$3" state_dir="$4" project="$5"
  python3 - "$SELFHOST_ROOT/.env.example" "$output" "$compose_file" "$encryption" \
    "$state_dir" "$project" <<'PY'
from pathlib import Path
import re
import sys

source, output, compose_file, encryption, state_dir, project = sys.argv[1:]
text = Path(source).read_text(encoding="utf-8")
values = {
    "DOMAIN": "matrix.example.org",
    "COMPOSE_PROJECT_NAME": project,
    "CHRONICLE_STATE_DIR": state_dir,
    "COMPOSE_FILE": compose_file,
    "ENABLE_ENCRYPTION": encryption,
    "HTTP_BIND": "127.0.0.1",
    "INTERNAL_BIND": "127.0.0.1",
    "DASHBOARD_PASSWORD_HASH": "'$2b$12$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'",
    "POSTGRES_PASSWORD": "matrix-postgres-password-not-a-secret",
    "JWT_SECRET": "matrix-jwt-signing-key-not-a-secret-123456789",
    "MOBILE_SIGNING_SECRET": "",
    "MOBILE_SIGNING_SECRET_PREVIOUS": "",
    "CHRONICLE_INTERNAL_WEB_SECRET": "matrix-internal-web-key-not-a-secret-123456",
    "TESTING_LOGIN_ENABLED": "true",
    "REQUIRE_MFA": "false",
    "MOBILE_SIGNING_ENABLED": "false",
    "MOBILE_SIGNING_REQUIRED": "false",
    "METRICS_PASSWORD": "matrix-metrics-password-not-a-secret-1234567",
    "GRAFANA_ADMIN_PASSWORD": "matrix-grafana-password-not-a-secret-1234567",
    "BACKEND_IMAGE": "ghcr.io/example/chronicle-backend@sha256:" + "a" * 64,
    "SELFHOST_FRONTEND_IMAGE": "ghcr.io/example/chronicle-frontend@sha256:" + "b" * 64,
    "CADDY_IMAGE": "ghcr.io/example/chronicle-caddy@sha256:" + "c" * 64,
}
for key, value in values.items():
    pattern = re.compile(rf"^{re.escape(key)}=.*$", re.MULTILINE)
    if len(pattern.findall(text)) != 1:
        raise SystemExit(f"expected exactly one {key} assignment in .env.example")
    text = pattern.sub(f"{key}={value}", text, count=1)
Path(output).write_text(text, encoding="utf-8")
PY
  chmod 600 "$output"
}

validate_render() {
  local config_json="$1" mode="$2" encryption="$3" backups="$4" monitoring="$5" tls_dir="$6"
  python3 - "$config_json" "$mode" "$encryption" "$backups" "$monitoring" \
    "$SELFHOST_ROOT/guard-config.sh" "$tls_dir" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

config_path, mode, encryption, backups_text, monitoring_text, guard, tls_dir = sys.argv[1:]
backups = backups_text == "true"
monitoring = monitoring_text == "true"
config = json.loads(Path(config_path).read_text(encoding="utf-8"))
services = config.get("services", {})

expected = {"config-guard", "cert-init", "db-init", "export-init", "postgres", "backend", "frontend", "web"}
if mode == "mode-local-https.yml":
    expected.add("ca-export")
if backups:
    expected.add("db-backup")
if monitoring:
    expected.update({"monitoring-config", "cadvisor", "operational-probe", "metrics-exporter",
                     "victoriametrics", "victorialogs", "fluent-bit", "grafana"})
if set(services) != expected:
    raise SystemExit(f"service set mismatch: expected {sorted(expected)}, got {sorted(services)}")
if any("build" in service for service in services.values()):
    raise SystemExit("rendered service contains a local build definition")
for name, service in services.items():
    image = service.get("image")
    if image and "@sha256:" not in image:
        raise SystemExit(f"{name} image is not digest pinned: {image}")

guard_environment = {key: str(value) for key, value in services["config-guard"].get("environment", {}).items()}
# `docker compose config` preserves a literal dollar as `$$`; the container receives one
# dollar when Compose launches it. Reproduce that final interpolation for the direct guard
# execution below.
guard_environment["DASHBOARD_PASSWORD_HASH"] = guard_environment.get("DASHBOARD_PASSWORD_HASH", "").replace("$$", "$")
expected_tls = "local-https" if mode == "mode-local-https.yml" else (
    "own-tls" if mode == "mode-own-tls-internal.yml" else "behind-proxy"
)
expected_guard = {
    "TLS_MODE": expected_tls,
    "DASHBOARD_EXPOSURE": "internal",
    "ENABLE_ENCRYPTION": encryption,
    "BACKUPS_ENABLED": backups_text,
    "MONITORING_ENABLED": monitoring_text,
    "AUTH_OVERLAY_ENABLED": "false",
    "TESTING_LOGIN_ENABLED": "true",
    "REQUIRE_MFA": "false",
}
for key, value in expected_guard.items():
    if guard_environment.get(key) != value:
        raise SystemExit(f"config-guard {key}: expected {value!r}, got {guard_environment.get(key)!r}")

optional = {
    "db-backup": backups,
    "cadvisor": monitoring,
    "monitoring-config": monitoring,
    "operational-probe": monitoring,
    "metrics-exporter": monitoring,
    "victoriametrics": monitoring,
    "victorialogs": monitoring,
    "fluent-bit": monitoring,
    "grafana": monitoring,
    "ca-export": mode == "mode-local-https.yml",
}
for service, wanted in optional.items():
    if (service in services) != wanted:
        raise SystemExit(f"optional service {service} presence does not match matrix")
if any(name.startswith("keycloak") for name in services):
    raise SystemExit("experimental Keycloak service leaked into a supported render")

mounts = services["web"].get("volumes", [])
caddy_mount = next((item for item in mounts if item.get("target") == "/etc/caddy/Caddyfile"), None)
expected_caddy = {
    "mode-behind-proxy-internal.yml": "Caddyfile.split",
    "mode-own-tls-internal.yml": "Caddyfile.split.tls",
    "mode-local-https.yml": "Caddyfile.split.local",
}[mode]
if caddy_mount is None or Path(caddy_mount.get("source", "")).name != expected_caddy:
    raise SystemExit(f"web Caddyfile mismatch for {mode}")

targets = {int(item["target"]) for item in services["web"].get("ports", [])}
expected_targets = {80, 8081} if mode == "mode-behind-proxy-internal.yml" else {80, 443, 8081}
if targets != expected_targets:
    raise SystemExit(f"published target ports mismatch: expected {expected_targets}, got {targets}")

guard_environment["PATH"] = os.environ.get("PATH", "/usr/bin:/bin")
guard_environment["CHRONICLE_GUARD_TLS_DIR"] = tls_dir
completed = subprocess.run(
    [guard],
    cwd=str(Path(guard).parent),
    env=guard_environment,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    timeout=10,
    check=False,
)
if completed.returncode != 0:
    raise SystemExit("guard rejected supported render:\n" + completed.stdout)
PY
}

case_count=0
baseline_json=""
for profile in "${profiles[@]}"; do
  IFS='|' read -r profile_id mode encryption backups <<< "$profile"
  for monitoring in false true; do
    case_count=$((case_count + 1))
    case_name="${profile_id}-monitoring-${monitoring}"
    case_dir="${RUN_DIR}/${case_name}"
    state_dir="${case_dir}/state"
    /bin/mkdir -p "${state_dir}/tls"
    printf 'matrix certificate\n' > "${state_dir}/tls/cert.pem"
    printf 'matrix private key\n' > "${state_dir}/tls/key.pem"
    chmod 600 "${state_dir}/tls/key.pem"

    compose_file="docker-compose.yml:overlays/${mode}"
    [[ "$backups" == true ]] && compose_file+=":overlays/backups.yml"
    [[ "$monitoring" == true ]] && compose_file+=":overlays/monitoring.yml"
    env_file="${case_dir}/matrix.env"
    /bin/mkdir -p "$case_dir"
    render_env "$env_file" "$compose_file" "$encryption" "$state_dir" \
      "chronicle-matrix-${case_count}"
    config_json="${case_dir}/compose.json"
    (
      cd "$DEPLOYMENT"
      "${TIMEOUT[@]}" 30s docker compose --env-file "$env_file" config --format json > "$config_json"
    ) || fail "Compose did not render ${case_name}"
    validate_render "$config_json" "$mode" "$encryption" "$backups" "$monitoring" "${state_dir}/tls" ||
      fail "render contract failed for ${case_name}"
    [[ -n "$baseline_json" ]] || baseline_json="$config_json"
    echo "  ok   ${case_name}"
  done
done
[[ $case_count -eq 14 ]] || fail "expected 14 rendered combinations, got ${case_count}"

# Mutate one known-good guard environment to prove unsupported shapes fail closed. This
# covers conditions that cannot be represented by the supported Compose files themselves.
python3 - "$baseline_json" "$SELFHOST_ROOT/guard-config.sh" "${RUN_DIR}/negative-tls" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

config_path, guard, tls_dir = sys.argv[1:]
Path(tls_dir).mkdir(parents=True, exist_ok=True)
(Path(tls_dir) / "cert.pem").write_text("fixture\n", encoding="utf-8")
(Path(tls_dir) / "key.pem").write_text("fixture\n", encoding="utf-8")
config = json.loads(Path(config_path).read_text(encoding="utf-8"))
base = {key: str(value) for key, value in config["services"]["config-guard"]["environment"].items()}
base["PATH"] = os.environ.get("PATH", "/usr/bin:/bin")
base["CHRONICLE_GUARD_TLS_DIR"] = tls_dir

cases = [
    ("production-without-backups", {"BACKUPS_ENABLED": "false", "ENABLE_ENCRYPTION": "false"}, "production deployment modes require"),
    ("encrypted-without-backups", {"TLS_MODE": "local-https", "BACKUPS_ENABLED": "false", "ENABLE_ENCRYPTION": "true", "COMPOSE_FILE_SELECTION": "docker-compose.yml:overlays/mode-local-https.yml"}, "encryption at rest is on"),
    ("no-login", {"TESTING_LOGIN_ENABLED": "false", "REQUIRE_MFA": "true"}, "no dashboard login method"),
    ("invalid-boolean", {"ENABLE_ENCRYPTION": "treu"}, "must be exactly true or false"),
    ("duplicate-mode", {"COMPOSE_FILE_SELECTION": "docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/mode-own-tls-internal.yml:overlays/backups.yml"}, "exactly one mode overlay"),
    ("public-without-auth", {"TLS_MODE": "behind-proxy", "DASHBOARD_EXPOSURE": "public", "TESTING_LOGIN_ENABLED": "false", "REQUIRE_MFA": "true", "AUTH_OVERLAY_ENABLED": "false", "COMPOSE_FILE_SELECTION": "docker-compose.yml:experimental/public-dashboard/mode-behind-proxy-public.yml:overlays/backups.yml"}, "public dashboard requires"),
]
for name, changes, expected in cases:
    environment = dict(base)
    environment.update(changes)
    completed = subprocess.run(
        [guard],
        cwd=str(Path(guard).parent),
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=10,
        check=False,
    )
    if completed.returncode == 0:
        raise SystemExit(f"guard accepted rejected shape {name}")
    if expected not in completed.stdout:
        raise SystemExit(f"guard rejection for {name} omitted {expected!r}:\n{completed.stdout}")
PY

echo "self-host combination matrix passed (${case_count} supported renders plus rejected-shape checks)"
