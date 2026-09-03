#!/usr/bin/env bash
set -Eeuo pipefail

# End-to-end proof for the artifact a self-hoster actually receives. The test builds and
# verifies release archives, extracts them under build/, starts the previous version without
# source-build access, exercises the guarded upgrade/backup/rollback/forward-recovery path,
# checks the public/internal boundary, forces dependency-order restart recovery, restores a
# generated SQL dump, and optionally proves the monitoring data path.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BUILDER="${ROOT_DIR}/scripts/build-selfhost-release.py"
RUN_PARENT="${SELFHOST_SMOKE_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-release-smoke}"
BACKEND_IMAGE="${SELFHOST_SMOKE_BACKEND_IMAGE:-}"
FRONTEND_IMAGE="${SELFHOST_SMOKE_FRONTEND_IMAGE:-}"
CADDY_IMAGE="${SELFHOST_SMOKE_CADDY_IMAGE:-}"
MONITORING="${SELFHOST_SMOKE_MONITORING:-true}"
SMOKE_PASSWORD='chronicle-smoke-only-password'

fail() {
  echo "self-host release smoke failed: $*" >&2
  exit 1
}

for command in docker jq python3 sha256sum tar; do
  command -v "$command" >/dev/null 2>&1 || fail "required command is unavailable: $command"
done
[[ -x "$BUILDER" ]] || fail "release builder is missing or not executable"
[[ -n "$BACKEND_IMAGE" ]] || fail "set SELFHOST_SMOKE_BACKEND_IMAGE"
[[ -n "$FRONTEND_IMAGE" ]] || fail "set SELFHOST_SMOKE_FRONTEND_IMAGE"
[[ -n "$CADDY_IMAGE" ]] || fail "set SELFHOST_SMOKE_CADDY_IMAGE"
[[ "$MONITORING" == true || "$MONITORING" == false ]] ||
  fail "SELFHOST_SMOKE_MONITORING must be true or false"
[[ "$RUN_PARENT" == /* ]] || fail "SELFHOST_SMOKE_ROOT must be absolute"
case "$RUN_PARENT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
    fail "SELFHOST_SMOKE_ROOT must not use a system temporary directory"
    ;;
esac

docker info >/dev/null 2>&1 || fail "Docker is unavailable"
docker compose version >/dev/null 2>&1 || fail "the Docker Compose plugin is unavailable"

umask 077
/bin/mkdir -p "$RUN_PARENT"
RUN_DIR="$(/usr/bin/mktemp -d "${RUN_PARENT}/run.XXXXXX")"
/bin/chmod 0700 "$RUN_DIR"
BUNDLE=""
OLD_BUNDLE=""
NEW_BUNDLE=""
PROJECT=""
SMOKE_PASSED=false

cleanup() {
  local original_status=$?
  set +e
  if [[ -n "$BUNDLE" && -d "$BUNDLE" && -n "$PROJECT" ]]; then
    (
      cd "$BUNDLE" || exit 0
      docker compose -p "$PROJECT" ps --all --format json >"${RUN_DIR}/final-compose-state.jsonl" 2>/dev/null
      docker compose -p "$PROJECT" down -v --remove-orphans >/dev/null 2>&1
    )
    OLD_BUNDLE_PATH="$OLD_BUNDLE" NEW_BUNDLE_PATH="$NEW_BUNDLE" python3 - <<'PY'
from pathlib import Path
import os

for variable in ("OLD_BUNDLE_PATH", "NEW_BUNDLE_PATH"):
    value = os.environ.get(variable, "")
    if value:
        (Path(value) / ".env").unlink(missing_ok=True)
PY
  fi
  if [[ "$SMOKE_PASSED" != true && ! -f "${RUN_DIR}/result.txt" ]]; then
    printf 'status=failed\n' >"${RUN_DIR}/result.txt"
  fi
  /bin/chmod 0600 "${RUN_DIR}/result.txt" 2>/dev/null || true
  if [[ "$SMOKE_PASSED" == true ]]; then
    printf 'Self-host release smoke passed; redacted evidence: %s/result.txt\n' "$RUN_DIR"
  else
    printf 'Self-host release smoke failed; evidence directory: %s\n' "$RUN_DIR" >&2
  fi
  return "$original_status"
}
trap cleanup EXIT

is_immutable_image() {
  [[ "$1" =~ @sha256:[0-9a-f]{64}$ ]]
}

# Local development images may be tags. The release builder correctly refuses those, so
# use synthetic immutable references in the artifact manifest and then replace only the
# extracted .env runtime references. CI passes real registry digests and takes no such
# development-only detour.
BUILDER_BACKEND_IMAGE="$BACKEND_IMAGE"
BUILDER_FRONTEND_IMAGE="$FRONTEND_IMAGE"
BUILDER_CADDY_IMAGE="$CADDY_IMAGE"
is_immutable_image "$BUILDER_BACKEND_IMAGE" ||
  BUILDER_BACKEND_IMAGE='ghcr.io/example/chronicle-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
is_immutable_image "$BUILDER_FRONTEND_IMAGE" ||
  BUILDER_FRONTEND_IMAGE='ghcr.io/example/chronicle-selfhost-frontend@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
is_immutable_image "$BUILDER_CADDY_IMAGE" ||
  BUILDER_CADDY_IMAGE='ghcr.io/example/chronicle-selfhost-caddy@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'

REVISION="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_DATE_EPOCH="$(git -C "$ROOT_DIR" show -s --format=%ct "$REVISION")"
ARTIFACT_DIR="${RUN_DIR}/artifacts"
OLD_VERSION='0.0.0-smoke.0'
NEW_VERSION='0.0.0-smoke.1'
OLD_ARCHIVE="${ARTIFACT_DIR}/chronicle-selfhost-${OLD_VERSION}.tar.gz"
NEW_ARCHIVE="${ARTIFACT_DIR}/chronicle-selfhost-${NEW_VERSION}.tar.gz"

printf 'Building and extracting source-free previous/current release archives.\n'
"$BUILDER" \
  --version "v${OLD_VERSION}" \
  --source-revision "$REVISION" \
  --source-date-epoch "$SOURCE_DATE_EPOCH" \
  --backend-image "$BUILDER_BACKEND_IMAGE" \
  --frontend-image "$BUILDER_FRONTEND_IMAGE" \
  --caddy-image "$BUILDER_CADDY_IMAGE" \
  --output-dir "$ARTIFACT_DIR" >/dev/null
"$BUILDER" \
  --version "v${NEW_VERSION}" \
  --source-revision "$REVISION" \
  --source-date-epoch "$SOURCE_DATE_EPOCH" \
  --backend-image "$BUILDER_BACKEND_IMAGE" \
  --frontend-image "$BUILDER_FRONTEND_IMAGE" \
  --caddy-image "$BUILDER_CADDY_IMAGE" \
  --output-dir "$ARTIFACT_DIR" >/dev/null
(cd "$ARTIFACT_DIR" && sha256sum -c "$(basename "${OLD_ARCHIVE}.sha256")" >/dev/null)
(cd "$ARTIFACT_DIR" && sha256sum -c "$(basename "${NEW_ARCHIVE}.sha256")" >/dev/null)
/bin/mkdir "${RUN_DIR}/extracted"
tar -xzf "$OLD_ARCHIVE" -C "${RUN_DIR}/extracted"
tar -xzf "$NEW_ARCHIVE" -C "${RUN_DIR}/extracted"
OLD_BUNDLE="${RUN_DIR}/extracted/chronicle-selfhost-${OLD_VERSION}/selfhost"
NEW_BUNDLE="${RUN_DIR}/extracted/chronicle-selfhost-${NEW_VERSION}/selfhost"
BUNDLE="$OLD_BUNDLE"

RUN_DIR="$RUN_DIR" \
OLD_BUNDLE="$OLD_BUNDLE" \
NEW_BUNDLE="$NEW_BUNDLE" \
RUNTIME_BACKEND_IMAGE="$BACKEND_IMAGE" \
RUNTIME_FRONTEND_IMAGE="$FRONTEND_IMAGE" \
RUNTIME_CADDY_IMAGE="$CADDY_IMAGE" \
ENABLE_MONITORING="$MONITORING" \
SMOKE_PASSWORD="$SMOKE_PASSWORD" \
python3 - <<'PY'
from pathlib import Path
import hashlib
import json
import os
import secrets
import socket
import subprocess

run_dir = Path(os.environ["RUN_DIR"])
old_bundle = Path(os.environ["OLD_BUNDLE"])
new_bundle = Path(os.environ["NEW_BUNDLE"])


def available_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


ports: list[int] = []
while len(ports) < 3:
    candidate = available_port()
    if candidate not in ports:
        ports.append(candidate)
http_port, internal_port, grafana_port = ports
project = f"chronicle-release-smoke-{os.getpid()}-{secrets.token_hex(3)}"
hashed = subprocess.check_output(
    [
        "docker",
        "run",
        "--rm",
        "-i",
        "--network",
        "none",
        "--entrypoint",
        "caddy",
        os.environ["RUNTIME_CADDY_IMAGE"],
        "hash-password",
    ],
    input=os.environ["SMOKE_PASSWORD"] + "\n",
    text=True,
).strip()
compose_file = (
    "docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/backups.yml"
)
if os.environ["ENABLE_MONITORING"] == "true":
    compose_file += ":overlays/monitoring.yml"
values = {
    # The behind-proxy fixture is a production-mode shape. Its public identity must
    # therefore pass the same globally routable-host guard as a real deployment even
    # though this smoke test reaches the bound listener through 127.0.0.1.
    "DOMAIN": "selfhost.example.org",
    "COMPOSE_PROJECT_NAME": project,
    "COMPOSE_FILE": compose_file,
    "HTTP_PORT": str(http_port),
    "INTERNAL_PORT": str(internal_port),
    "DASHBOARD_PASSWORD_HASH": f"'{hashed}'",
    "POSTGRES_PASSWORD": secrets.token_urlsafe(48),
    "JWT_SECRET": secrets.token_urlsafe(48),
    "MOBILE_SIGNING_ENABLED": "false",
    "MOBILE_SIGNING_REQUIRED": "false",
    "MOBILE_SIGNING_SECRET": "",
    "CHRONICLE_INTERNAL_WEB_SECRET": secrets.token_urlsafe(48),
    "METRICS_PASSWORD": secrets.token_urlsafe(48),
    "GRAFANA_ADMIN_PASSWORD": secrets.token_urlsafe(48),
    "GRAFANA_BIND": "127.0.0.1",
    "GRAFANA_PORT": str(grafana_port),
    "BACKEND_IMAGE": os.environ["RUNTIME_BACKEND_IMAGE"],
    "SELFHOST_FRONTEND_IMAGE": os.environ["RUNTIME_FRONTEND_IMAGE"],
    "CADDY_IMAGE": os.environ["RUNTIME_CADDY_IMAGE"],
    "TESTING_LOGIN_ENABLED": "true",
    "REQUIRE_MFA": "false",
    "BACKUP_STARTUP_TIMEOUT_SECONDS": "180",
}
runtime_images = {
    "BACKEND_IMAGE": os.environ["RUNTIME_BACKEND_IMAGE"],
    "SELFHOST_FRONTEND_IMAGE": os.environ["RUNTIME_FRONTEND_IMAGE"],
    "CADDY_IMAGE": os.environ["RUNTIME_CADDY_IMAGE"],
}


def use_runtime_images(bundle: Path) -> None:
    env_path = bundle / ".env.example"
    lines = env_path.read_text(encoding="utf-8").splitlines()
    rendered = []
    seen = set()
    for line in lines:
        if "=" in line and not line.lstrip().startswith("#"):
            key = line.split("=", 1)[0]
            if key in runtime_images:
                line = f"{key}={runtime_images[key]}"
                seen.add(key)
        rendered.append(line)
    missing = sorted(set(runtime_images) - seen)
    if missing:
        raise SystemExit(f"missing runtime image keys: {', '.join(missing)}")
    env_path.write_text("\n".join(rendered) + "\n", encoding="utf-8")
    manifest_path = bundle.parent / "release-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["images"] = {
        "backend": runtime_images["BACKEND_IMAGE"],
        "frontend": runtime_images["SELFHOST_FRONTEND_IMAGE"],
        "caddy": runtime_images["CADDY_IMAGE"],
    }
    manifest["files"]["selfhost/.env.example"] = hashlib.sha256(env_path.read_bytes()).hexdigest()
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


# Local development tags cannot be placed in the published archive because the builder
# correctly rejects mutable refs. The archive checksum/source-free checks happen first;
# only the extracted runtime fixtures are then pointed at already-built local images. CI
# passes registry digests, so these replacements are byte-identical there.
use_runtime_images(old_bundle)
use_runtime_images(new_bundle)

lines = (old_bundle / ".env.example").read_text(encoding="utf-8").splitlines()
rendered: list[str] = []
seen: set[str] = set()
for line in lines:
    if "=" in line and not line.lstrip().startswith("#"):
        key = line.split("=", 1)[0]
        if key in values:
            line = f"{key}={values[key]}"
            seen.add(key)
    rendered.append(line)
missing = sorted(set(values) - seen)
if missing:
    raise SystemExit(f"missing expected .env keys: {', '.join(missing)}")
env_path = old_bundle / ".env"
env_path.write_text("\n".join(rendered) + "\n", encoding="utf-8")
env_path.chmod(0o600)
(run_dir / "smoke-metadata.txt").write_text(
    f"project={project}\n"
    f"http_port={http_port}\n"
    f"internal_port={internal_port}\n"
    f"grafana_port={grafana_port}\n",
    encoding="utf-8",
)
PY

# The metadata contains no secrets and uses shell-safe generated values.
project=""
http_port=""
internal_port=""
grafana_port=""
# shellcheck disable=SC1090
source "${RUN_DIR}/smoke-metadata.txt"
[[ -n "$project" && -n "$http_port" && -n "$internal_port" && -n "$grafana_port" ]] ||
  fail "generated smoke metadata is incomplete"
PROJECT="$project"

for candidate_bundle in "$OLD_BUNDLE" "$NEW_BUNDLE"; do
  (
    cd "$candidate_bundle"
    ./verify-config.sh >/dev/null
    compose_args=()
    [[ -f .env ]] || compose_args=(--env-file .env.example)
    docker compose "${compose_args[@]}" config --quiet
    if docker compose "${compose_args[@]}" config --format json | jq -e 'any(.services[]; has("build"))' >/dev/null; then
      fail "extracted release Compose contains a source build: $candidate_bundle"
    fi
  )
done

cd "$OLD_BUNDLE"
verify_with_dashboard_password() {
  printf '%s\n' "$SMOKE_PASSWORD" | ./chronicle verify --dashboard-password
}
./chronicle check
printf 'Starting isolated previous-release project %s (bounded wait: 300s).\n' "$PROJECT"
docker compose up -d --wait --wait-timeout 300
verify_with_dashboard_password

id_range_state="$({
  docker compose exec -T postgres /bin/bash -ceu \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAqc "SELECT count(*) || '\''|'\'' || count(*) FILTER (WHERE msb <> 0) || '\''|'\'' || bool_and(lsb < 0) FROM public.id_gen"'
} | tr -d '[:space:]')"
[[ "$id_range_state" == '65536|0|true' ]] ||
  fail "ID generation ranges are incomplete or do not preserve the initial Range cursor: ${id_range_state}"
printf 'Verified 65,536 partition-safe ID generation ranges.\n'

printf 'Writing a database sentinel before the version transition.\n'
docker compose exec -T postgres /bin/bash -ceu \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q' <<'SQL'
CREATE TABLE IF NOT EXISTS upgrade_smoke_sentinel (
  id integer PRIMARY KEY,
  marker text NOT NULL
);
INSERT INTO upgrade_smoke_sentinel (id, marker)
VALUES (1, 'before-upgrade')
ON CONFLICT (id) DO UPDATE SET marker = EXCLUDED.marker;
SQL

sentinel_marker() {
  docker compose exec -T postgres /bin/bash -ceu \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAqc "SELECT marker FROM upgrade_smoke_sentinel WHERE id = 1"'
}
[[ "$(sentinel_marker)" == before-upgrade ]] || fail "pre-upgrade database sentinel is missing"

printf 'Exercising guarded previous-version upgrade with automatic backup.\n'
BUNDLE="$NEW_BUNDLE"
cd "$NEW_BUNDLE"
# Exported values have higher Compose interpolation precedence than .env. Poison the
# high-impact controls deliberately: the upgrade command must isolate them and use only the
# validated old/new release files. Success proves it did not select the restore profile,
# another project, an untrusted Compose file, or an inherited image override.
DASHBOARD_PASSWORD="$SMOKE_PASSWORD" UPGRADE_WAIT_TIMEOUT_SECONDS=300 \
COMPOSE_FILE="${RUN_DIR}/must-not-be-used.yml" COMPOSE_PROFILES=restore \
COMPOSE_PROJECT_NAME=must-not-be-used BACKEND_IMAGE=must-not-be-used:latest \
  ./chronicle upgrade --from "$OLD_BUNDLE"

upgrade_line="$(
  OLD_BUNDLE="$OLD_BUNDLE" NEW_BUNDLE="$NEW_BUNDLE" \
  EXPECTED_VERSION="$NEW_VERSION" \
  EXPECTED_BACKEND_IMAGE="$BACKEND_IMAGE" \
  EXPECTED_FRONTEND_IMAGE="$FRONTEND_IMAGE" \
  EXPECTED_CADDY_IMAGE="$CADDY_IMAGE" \
  python3 - <<'PY'
from pathlib import Path
import hashlib
import json
import os
import re

old_bundle = Path(os.environ["OLD_BUNDLE"]).resolve()
new_bundle = Path(os.environ["NEW_BUNDLE"]).resolve()
values = {}
for line in (new_bundle / ".env").read_text(encoding="utf-8").splitlines():
    match = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
    if match:
        value = match.group(2)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values[match.group(1)] = value
expected = {
    "RELEASE_VERSION": os.environ["EXPECTED_VERSION"],
    "BACKEND_IMAGE": os.environ["EXPECTED_BACKEND_IMAGE"],
    "SELFHOST_FRONTEND_IMAGE": os.environ["EXPECTED_FRONTEND_IMAGE"],
    "CADDY_IMAGE": os.environ["EXPECTED_CADDY_IMAGE"],
    "CHRONICLE_STATE_DIR": str(old_bundle),
}
for key, wanted in expected.items():
    if values.get(key) != wanted:
        raise SystemExit(f"upgraded .env has {key}={values.get(key)!r}, expected {wanted!r}")

receipts = sorted((old_bundle / "upgrade-receipts").glob("*.json"))
if len(receipts) != 1:
    raise SystemExit(f"expected one upgrade receipt, found {len(receipts)}")
receipt = receipts[0]
payload = json.loads(receipt.read_text(encoding="utf-8"))
if payload.get("status") != "succeeded":
    raise SystemExit(f"upgrade receipt status is {payload.get('status')!r}")
if payload.get("from", {}).get("version") != "0.0.0-smoke.0":
    raise SystemExit("upgrade receipt has wrong previous version")
if payload.get("to", {}).get("version") != os.environ["EXPECTED_VERSION"]:
    raise SystemExit("upgrade receipt has wrong target version")
backup = Path(payload["pre_upgrade_backup"]["path"])
if backup.parent != old_bundle / "backups" or not backup.is_file():
    raise SystemExit(f"pre-upgrade backup is outside preserved state: {backup}")
actual = hashlib.sha256(backup.read_bytes()).hexdigest()
if actual != payload["pre_upgrade_backup"]["sha256"]:
    raise SystemExit("pre-upgrade backup checksum does not match receipt")
if receipt.stat().st_mode & 0o077:
    raise SystemExit("upgrade receipt is readable outside its owner")
print("\t".join([str(backup), f"/backups/{backup.name}", str(receipt)]))
PY
)" || fail "upgrade state/receipt contract failed"
IFS=$'\t' read -r PRE_UPGRADE_BACKUP PRE_UPGRADE_CONTAINER_PATH UPGRADE_RECEIPT <<<"$upgrade_line"
[[ -n "$PRE_UPGRADE_BACKUP" && -n "$PRE_UPGRADE_CONTAINER_PATH" && -n "$UPGRADE_RECEIPT" ]] ||
  fail "upgrade metadata is incomplete"
[[ -s "$UPGRADE_RECEIPT" ]] || fail "upgrade receipt is missing after validation"
gzip -t "$PRE_UPGRADE_BACKUP" || fail "pre-upgrade backup is not valid gzip"
[[ ! -e "${OLD_BUNDLE}/.chronicle-upgrade.lock" ]] || fail "upgrade ownership lock was not released"
[[ "$(sentinel_marker)" == before-upgrade ]] || fail "upgrade did not preserve database state"

printf 'Changing the sentinel, then exercising the documented schema-safe rollback.\n'
docker compose exec -T postgres /bin/bash -ceu \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -qc "UPDATE upgrade_smoke_sentinel SET marker = '\''after-upgrade'\'' WHERE id = 1"'
[[ "$(sentinel_marker)" == after-upgrade ]] || fail "post-upgrade sentinel mutation failed"
./chronicle restore --yes --no-start "$PRE_UPGRADE_CONTAINER_PATH"
[[ ! -e "${OLD_BUNDLE}/.chronicle-restore.lock" ]] || fail "rollback restore lock was not released"
docker compose down

BUNDLE="$OLD_BUNDLE"
cd "$OLD_BUNDLE"
docker compose up -d --wait --wait-timeout 300
verify_with_dashboard_password >/dev/null
[[ "$(sentinel_marker)" == before-upgrade ]] || fail "rollback did not restore pre-upgrade data"

printf 'Starting the new release again to prove forward recovery after rollback.\n'
docker compose down
BUNDLE="$NEW_BUNDLE"
cd "$NEW_BUNDLE"
docker compose up -d --wait --wait-timeout 300 --remove-orphans
verify_with_dashboard_password >/dev/null
[[ "$(sentinel_marker)" == before-upgrade ]] || fail "forward recovery lost restored data"

active_tde_key() {
  docker compose exec -T postgres /bin/bash -ceu \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -qAt -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT key_name FROM pg_tde_key_info();"'
}

printf 'Rotating the TDE principal key and proving db-init preserves it across reruns.\n'
pre_rotation_key="$(active_tde_key)"
./chronicle rotate-secret --yes tde
rotated_key="$(active_tde_key)"
[[ -n "$rotated_key" && "$rotated_key" != "$pre_rotation_key" ]] \
  || fail "TDE rotation did not advance the active principal key"
docker compose run --rm --no-deps db-init >/dev/null
[[ "$(active_tde_key)" == "$rotated_key" ]] \
  || fail "db-init reset the rotated TDE principal key"
[[ -s "${OLD_BUNDLE}/backups/keyring/chronicle-keyring.per" ]] \
  || fail "TDE rotation did not retain a recoverable keyring copy"
verify_with_dashboard_password >/dev/null

service_container() {
  local service="$1" container
  container="$(docker compose ps -q "$service")"
  [[ -n "$container" ]] || fail "service has no container: $service"
  printf '%s' "$container"
}

wait_healthy_container() {
  local container="$1" timeout_seconds="$2" label="$3"
  local started_at=$SECONDS health_state
  while (( SECONDS - started_at < timeout_seconds )); do
    health_state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container")"
    if [[ "$health_state" == healthy ]]; then
      printf '%s is healthy.\n' "$label"
      return 0
    fi
    if [[ "$health_state" == exited || "$health_state" == dead ]]; then
      fail "$label entered state $health_state"
    fi
    sleep 2
  done
  fail "$label did not become healthy within ${timeout_seconds}s"
}

if [[ "$MONITORING" == true ]]; then
  printf 'Proving the supported cAdvisor -> VictoriaMetrics -> Grafana path.\n'
  curl -fsS "http://127.0.0.1:${grafana_port}/api/health" | jq -e '.database == "ok"' >/dev/null
  monitoring_deadline=$((SECONDS + 60))
  monitoring_target_ready=false
  while (( SECONDS < monitoring_deadline )); do
    if docker compose exec -T grafana wget -qO- http://victoriametrics:8428/api/v1/targets \
      >"${RUN_DIR}/vm-targets.json" &&
      jq -e '.status == "success" and any(.data.activeTargets[]?; .health == "up" and .labels.job == "chronicle-containers")' \
        "${RUN_DIR}/vm-targets.json" >/dev/null; then
      monitoring_target_ready=true
      break
    fi
    sleep 2
  done
  [[ "$monitoring_target_ready" == true ]] || fail "cAdvisor scrape target did not become healthy"

  # `up` is emitted by the VictoriaMetrics scraper for this exact cAdvisor job and is
  # stable across cAdvisor releases. Component-specific informational metric names are not.
  monitoring_deadline=$((SECONDS + 60))
  monitoring_sample_ready=false
  while (( SECONDS < monitoring_deadline )); do
    if docker compose exec -T grafana wget -qO- \
      'http://victoriametrics:8428/api/v1/query?query=up%7Bjob%3D%22chronicle-containers%22%7D%20%3D%3D%201' \
      >"${RUN_DIR}/vm-query.json" &&
      jq -e '.status == "success" and (.data.result | length >= 1)' "${RUN_DIR}/vm-query.json" >/dev/null; then
      monitoring_sample_ready=true
      break
    fi
    sleep 2
  done
  [[ "$monitoring_sample_ready" == true ]] || fail "VictoriaMetrics did not ingest the cAdvisor scrape result"
  BUNDLE="$BUNDLE" GRAFANA_PORT="$grafana_port" python3 - <<'PY'
from base64 import b64encode
import json
import os
from pathlib import Path
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

password = ""
for line in (Path(os.environ["BUNDLE"]) / ".env").read_text(encoding="utf-8").splitlines():
    if line.startswith("GRAFANA_ADMIN_PASSWORD="):
        password = line.split("=", 1)[1]
        break
if not password:
    raise SystemExit("generated Grafana password is unavailable")
authorization = b64encode(f"admin:{password}".encode()).decode()
base = f"http://127.0.0.1:{os.environ['GRAFANA_PORT']}"
checks = {
    "/api/datasources/uid/chronicle-victoriametrics": ("uid", "chronicle-victoriametrics"),
    "/api/dashboards/uid/chronicle-containers": ("meta", None),
}
deadline = time.monotonic() + 60
pending = set(checks)
while pending and time.monotonic() < deadline:
    for endpoint in list(pending):
        request = Request(endpoint if endpoint.startswith("http") else base + endpoint)
        request.add_header("Authorization", f"Basic {authorization}")
        try:
            with urlopen(request, timeout=5) as response:
                payload = json.load(response)
            key, expected = checks[endpoint]
            if key == "uid" and payload.get(key) == expected:
                pending.remove(endpoint)
            elif key == "meta" and payload.get("dashboard", {}).get("uid") == "chronicle-containers":
                pending.remove(endpoint)
        except (HTTPError, URLError, TimeoutError, json.JSONDecodeError):
            pass
    if pending:
        time.sleep(2)
if pending:
    raise SystemExit(f"Grafana provisioning did not become ready: {sorted(pending)}")
PY
fi

backup_container="$(service_container db-backup)"
backend_container="$(service_container backend)"
postgres_container="$(service_container postgres)"

printf 'Forcing restart-order inversion: backup first, dependencies unavailable.\n'
docker stop "$backup_container" "$backend_container" "$postgres_container" >/dev/null
docker start "$backup_container" >/dev/null
sleep 3
[[ "$(docker inspect --format '{{.State.Status}}' "$backup_container")" == running ]] ||
  fail "backup wrapper exited instead of waiting for dependencies"
docker logs "$backup_container" 2>&1 | grep -F 'Waiting for backup dependencies' >/dev/null ||
  fail "backup wrapper did not report dependency waiting"
docker start "$postgres_container" >/dev/null
wait_healthy_container "$postgres_container" 90 'PostgreSQL'
docker start "$backend_container" >/dev/null
wait_healthy_container "$backend_container" 240 'Backend'
wait_healthy_container "$backup_container" 90 'Backup sidecar'
docker logs "$backup_container" 2>&1 | grep -F 'Backup dependencies are ready' >/dev/null ||
  fail "backup wrapper did not hand off after dependency recovery"
verify_with_dashboard_password >/dev/null

printf 'Restoring the newest generated dump into the isolated database.\n'
./chronicle restore --yes
[[ ! -e "${OLD_BUNDLE}/.chronicle-restore.lock" ]] || fail "clean restore lock was not released"
verify_with_dashboard_password >/dev/null

{
  echo 'status=passed'
  echo 'source_free_archive=pass'
  echo 'fresh_install=pass'
  echo 'previous_version_upgrade=pass'
  echo 'automatic_pre_upgrade_backup=pass'
  echo 'upgrade_environment_isolation=pass'
  echo 'upgrade_state_continuity=pass'
  echo 'schema_safe_rollback=pass'
  echo 'forward_recovery=pass'
  echo 'tde_rotation_restart_continuity=pass'
  echo 'tde_rotated_keyring_backup=pass'
  echo 'external_boundary_verify=pass'
  echo 'restart_order_recovery=pass'
  echo 'clean_restore=pass'
  echo 'post_restore_verify=pass'
  echo "monitoring=${MONITORING}"
  [[ "$MONITORING" != true ]] || echo 'monitoring_data_path=pass'
  echo "source_revision=${REVISION}"
} >"${RUN_DIR}/result.txt"
SMOKE_PASSED=true
