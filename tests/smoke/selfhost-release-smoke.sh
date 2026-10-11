#!/usr/bin/env bash
set -Eeuo pipefail
export CHRONICLE_RECONCILE_ENABLED="${CHRONICLE_RECONCILE_ENABLED:-false}"
# The isolated 256 MiB PostgreSQL volume deliberately exercises ENOSPC. Image/download
# reserves still apply on Docker/state storage; platform qualification tests the default floor.
export MIN_FREE_DISK_GIB=0

# End-to-end proof for the artifact a self-hoster actually receives. The test builds and
# verifies release archives, extracts them under build/, starts the previous version without
# source-build access, exercises the guarded upgrade/backup/rollback/forward-recovery path,
# checks the public/internal boundary, forces dependency-order restart recovery, restores a
# generated SQL dump, and optionally proves the monitoring data path.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BUILDER="${ROOT_DIR}/scripts/build-selfhost-release.py"
RUN_PARENT="${SELFHOST_SMOKE_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-release-smoke}"
BACKEND_IMAGE="${SELFHOST_SMOKE_BACKEND_IMAGE:-}"
# Backend the "previous" bundle runs. When a published previous-release archive is
# supplied, its manifest pin is used unless SELFHOST_SMOKE_PREVIOUS_BACKEND_IMAGE overrides it.
PREVIOUS_BACKEND_IMAGE="${SELFHOST_SMOKE_PREVIOUS_BACKEND_IMAGE:-}"
FRONTEND_IMAGE="${SELFHOST_SMOKE_FRONTEND_IMAGE:-}"
CADDY_IMAGE="${SELFHOST_SMOKE_CADDY_IMAGE:-}"
# Optional locally built backup sidecar. Its pin lives in overlays/backups.yml, not .env, so
# without this the drill runs the previously published backup image and never its self-check.
BACKUP_IMAGE="${SELFHOST_SMOKE_BACKUP_IMAGE:-}"
RELEASE_ARCHIVE="${SELFHOST_SMOKE_RELEASE_ARCHIVE:-}"
RELEASE_SHA256_FILE="${SELFHOST_SMOKE_RELEASE_SHA256_FILE:-${RELEASE_ARCHIVE}.sha256}"
RELEASE_SIGNATURE_FILE="${SELFHOST_SMOKE_RELEASE_SIGNATURE_FILE:-${RELEASE_SHA256_FILE}.sig}"
RELEASE_ARCHIVE_SHA256=""
MONITORING="${SELFHOST_SMOKE_MONITORING:-true}"
SMOKE_PASSWORD='chronicle-smoke-only-password'
DISK_SMOKE_VOLUME_BYTES=268435456
DISK_DRILL_MAX_SECONDS=60

operator_crontab() {
  if command -v crontab >/dev/null 2>&1; then
    crontab -l 2>/dev/null || [[ $? == 1 ]]
  fi
}

fail() {
  echo "self-host release smoke failed: $*" >&2
  exit 1
}

run_container_security_audit() { # <report-path>
  local report="$1" status
  if COMPOSE_PROJECT="$PROJECT" "${ROOT_DIR}/tests/security/container-security-tests.sh" \
      >"$report" 2>&1; then
    container_security_audit=pass
    return 0
  else
    status=$?
  fi
  container_security_audit=fail
  cat "$report" >&2
  fail "container security audit failed (exit ${status}); see ${report}"
}

bounded_curl() { # Every smoke HTTP request has a short connection and total deadline.
  curl --connect-timeout 5 --max-time 15 "$@"
}

[[ "${SELFHOST_SMOKE_ALLOW_SYNTHETIC_PREDECESSOR:-false}" == false ||
   "${SELFHOST_SMOKE_ALLOW_SYNTHETIC_PREDECESSOR:-false}" == true ]] ||
  fail "SELFHOST_SMOKE_ALLOW_SYNTHETIC_PREDECESSOR must be true or false"
if [[ -z "${SELFHOST_SMOKE_PREVIOUS_RELEASE_ARCHIVE:-}" &&
      "${SELFHOST_SMOKE_ALLOW_SYNTHETIC_PREDECESSOR:-false}" != true ]]; then
  fail "release mode requires a published SELFHOST_SMOKE_PREVIOUS_RELEASE_ARCHIVE and verified checksum; local checks may explicitly set SELFHOST_SMOKE_ALLOW_SYNTHETIC_PREDECESSOR=true"
fi
if [[ -z "$RELEASE_ARCHIVE" && "${SELFHOST_SMOKE_ALLOW_SYNTHETIC_PREDECESSOR:-false}" != true ]]; then
  fail "release mode requires SELFHOST_SMOKE_RELEASE_ARCHIVE and its signed checksum"
fi

for command in docker jq python3 sha256sum tar ssh-keygen; do
  command -v "$command" >/dev/null 2>&1 || fail "required command is unavailable: $command"
done
[[ -x "$BUILDER" ]] || fail "release builder is missing or not executable"
[[ -n "$BACKEND_IMAGE" ]] || fail "set SELFHOST_SMOKE_BACKEND_IMAGE"
[[ -n "$FRONTEND_IMAGE" ]] || fail "set SELFHOST_SMOKE_FRONTEND_IMAGE"
[[ -n "$CADDY_IMAGE" ]] || fail "set SELFHOST_SMOKE_CADDY_IMAGE"
[[ -z "$RELEASE_ARCHIVE" || -n "$BACKUP_IMAGE" ]] || fail "set SELFHOST_SMOKE_BACKUP_IMAGE to the candidate backup pin"
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
# The stack is started with plain `docker compose up` below to keep --wait semantics; the
# `./chronicle` wrapper exports these so db-backup runs as the operator (overlays/backups.yml),
# and `./chronicle verify` fails on root-owned dumps without them.
CHRONICLE_HOST_UID="$(id -u)"
CHRONICLE_HOST_GID="$(id -g)"
export CHRONICLE_HOST_UID CHRONICLE_HOST_GID
/bin/mkdir -p "$RUN_PARENT"
RUN_DIR="$(/usr/bin/mktemp -d "${RUN_PARENT}/run.XXXXXX")"
/bin/chmod 0700 "$RUN_DIR"
BUNDLE=""
OLD_BUNDLE=""
NEW_BUNDLE=""
ROLLED_BACK_BUNDLE=""
FRESH_BUNDLE=""
fresh_install=not_run
PROJECT=""
SMOKE_PASSED=false
UPDATE_SERVER_PID=""
REDIRECT_SERVER_PID=""
TLS_PROXY_CONTAINER=""
DISK_VOLUME_KEEPER=""
DOCKER_EVENT_PIDS=""
operator_crontab >"${RUN_DIR}/crontab-before" || fail "could not snapshot the operator crontab"

cleanup() {
  local original_status=$?
  set +e
  [[ -z "$TLS_PROXY_CONTAINER" ]] || docker rm -f "$TLS_PROXY_CONTAINER" >/dev/null 2>&1
  if [[ -n "$REDIRECT_SERVER_PID" ]]; then
    kill "$REDIRECT_SERVER_PID" 2>/dev/null || true
    wait "$REDIRECT_SERVER_PID" 2>/dev/null || true
  fi
  local event_pid
  for event_pid in $DOCKER_EVENT_PIDS; do
    kill "$event_pid" 2>/dev/null || true
    wait "$event_pid" 2>/dev/null || true
  done
  if [[ -n "$UPDATE_SERVER_PID" ]]; then
    kill "$UPDATE_SERVER_PID" 2>/dev/null || true
    wait "$UPDATE_SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "$BUNDLE" && -d "$BUNDLE" && -n "$PROJECT" ]]; then
    (
      cd "$BUNDLE" || exit 0
      docker compose -p "$PROJECT" ps --all --format json >"${RUN_DIR}/final-compose-state.jsonl" 2>/dev/null
      # A failed run's only diagnosis is the container output; the stack is gone after down.
      if [[ "$SMOKE_PASSED" != true ]]; then
        docker compose -p "$PROJECT" logs --no-color --tail 300 >"${RUN_DIR}/final-compose-logs.txt" 2>&1
        # shellcheck disable=SC2046
        docker network inspect $(docker network ls -q --filter "label=com.docker.compose.project=$PROJECT") \
          >"${RUN_DIR}/final-networks.json" 2>&1
      fi
      [[ -z "$DISK_VOLUME_KEEPER" ]] || docker rm -f "$DISK_VOLUME_KEEPER" >/dev/null 2>&1
      docker compose -p "$PROJECT" down -v --remove-orphans >/dev/null 2>&1
    )
    OLD_BUNDLE_PATH="$OLD_BUNDLE" NEW_BUNDLE_PATH="$NEW_BUNDLE" FRESH_BUNDLE_PATH="$FRESH_BUNDLE" \
    ROLLED_BACK_BUNDLE_PATH="$ROLLED_BACK_BUNDLE" python3 - <<'PY'
from pathlib import Path
import os

for variable in ("OLD_BUNDLE_PATH", "NEW_BUNDLE_PATH", "FRESH_BUNDLE_PATH", "ROLLED_BACK_BUNDLE_PATH"):
    value = os.environ.get(variable, "")
    if value:
        (Path(value) / ".env").unlink(missing_ok=True)
PY
  fi
  if ! operator_crontab >"${RUN_DIR}/crontab-after" ||
     ! cmp -s "${RUN_DIR}/crontab-before" "${RUN_DIR}/crontab-after"; then
    echo 'self-host release smoke changed the operator crontab' >&2
    SMOKE_PASSED=false
    original_status=1
    printf 'status=failed\n' >"${RUN_DIR}/result.txt"
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

verify_release_signature() {
  python3 - "$BUILDER" "$1" "$2" "$3" <<'PY_SIGNATURE'
from pathlib import Path
import runpy
import sys
builder, checksum, signature, key = map(Path, sys.argv[1:])
helpers = runpy.run_path(str(builder))
helpers['verify_release_signature'](checksum, signature, key)
print(helpers['SMOKE_ARCHIVE_HASH_FIELD'])
PY_SIGNATURE
}

inspect_release_archive() { # <archive> <sha256-sidecar> [signature] -> version, source revision, backend pin
  python3 - "$1" "$2" "$BUILDER" "${3:-}" <<'PY'
import json
import os
from pathlib import Path, PurePosixPath
import re
import runpy
import sys
import tarfile

archive_path, checksum_path = map(Path, sys.argv[1:3])
if not archive_path.is_file() or archive_path.is_symlink():
    raise SystemExit("previous release archive must be a regular file")
if not checksum_path.is_file() or checksum_path.is_symlink():
    raise SystemExit("previous release SHA-256 sidecar must be a regular file")
helpers = runpy.run_path(sys.argv[3])
if sys.argv[4]:
    helpers['require_trusted_release_archive'](
        archive_path, checksum_path, Path(sys.argv[4]),
        Path(os.environ.get('CHRONICLE_RELEASE_VERIFY_KEY', helpers['SELFHOST'] / 'release-signing.pub')),
        os.environ.get(helpers['PREVIOUS_RELEASE_TRUSTED_SHA256_ENV'], ''))
else:
    helpers['require_archive_checksum'](archive_path, checksum_path)
with tarfile.open(archive_path, "r:gz") as archive:
    members = archive.getmembers()
    if len(members) > 20000 or sum(member.size for member in members) > 2 * 1024 * 1024 * 1024:
        raise SystemExit("previous release archive exceeds the supported inventory bounds")
    manifests = [member for member in members
                 if member.name.endswith("/release-manifest.json") and member.isfile()]
    if len(manifests) != 1:
        raise SystemExit("previous release archive must contain one release manifest")
    manifest_member = manifests[0]
    root = manifest_member.name.removesuffix("/release-manifest.json")
    manifest = json.load(archive.extractfile(manifest_member))
    version = manifest.get("release_version")
    revision = manifest.get("source_revision")
    backend = manifest.get("images", {}).get("backend", "")
    if not isinstance(version, str) or not re.fullmatch(
            r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
            r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
            r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?", version):
        raise SystemExit("previous release manifest has an invalid version")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise SystemExit("previous release manifest has an invalid source revision")
    if not isinstance(backend, str) or not backend or "\t" in backend:
        raise SystemExit("previous release manifest has no safe backend image pin")
    if archive_path.name != f"{root}.tar.gz":
        raise SystemExit("previous release archive name does not match its bundle root")
    for member in members:
        path = PurePosixPath(member.name)
        if (path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != root
                or not (member.isdir() or member.isfile())):
            raise SystemExit("previous release archive contains an unsafe member")
        if any(part == ".env" or part.endswith((".pem", ".key", ".jks", ".p12"))
               or part == "signing.properties" for part in path.parts):
            raise SystemExit("previous release archive contains runtime-only material")
    operator = [member for member in members
                if member.name == f"{root}/selfhost/chronicle" and member.isfile()]
    if len(operator) != 1 or not operator[0].mode & 0o111:
        raise SystemExit("previous release archive is missing its executable operator CLI")
print("\t".join((version, revision, backend)))
PY
}

latest_changelog_version() {
  python3 - "$ROOT_DIR/CHANGELOG.md" "${1:-0}" <<'PY'
from pathlib import Path
import re
import sys

versions = []
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    match = re.fullmatch(r"## \[([^]]+)\](?:\s+.*)?", line)
    if match and match[1] != "Unreleased":
        versions.append(match[1])
try:
    print(versions[int(sys.argv[2])])
except IndexError:
    raise SystemExit("CHANGELOG.md has no released version for the requested smoke bundle")
PY
}

version_is_newer() { # <candidate> <baseline>
  python3 - "$1" "$2" <<'PY'
import re
import sys

version_re = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
)


def key(version):
    match = version_re.fullmatch(version)
    if not match:
        raise SystemExit(f"invalid semantic version: {version!r}")
    prerelease = match.group(4)
    parts = []
    for part in prerelease.split(".") if prerelease else []:
        if part.isdigit() and len(part) > 1 and part.startswith("0"):
            raise SystemExit(f"invalid numeric prerelease identifier: {part!r}")
        parts.append((0, int(part)) if part.isdigit() else (1, part))
    return (*map(int, match.group(1, 2, 3)), (0, *parts) if prerelease else (1,))


raise SystemExit(0 if key(sys.argv[1]) > key(sys.argv[2]) else 1)
PY
}

# The release builder and `up` both refuse mutable tags, so every image is a digest
# reference: CI passes registry digests; local runs push to a loopback registry first.
for image in "$BACKEND_IMAGE" "$FRONTEND_IMAGE" "$CADDY_IMAGE" ${BACKUP_IMAGE:+"$BACKUP_IMAGE"}; do
  is_immutable_image "$image" ||
    fail "$image is not a digest reference; push it to a registry (e.g. localhost:5000) and pass name@sha256:..."
done

REVISION="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_DATE_EPOCH="$(git -C "$ROOT_DIR" show -s --format=%ct "$REVISION")"
ARTIFACT_DIR="${RUN_DIR}/artifacts"
PREVIOUS_RELEASE_ARCHIVE="${SELFHOST_SMOKE_PREVIOUS_RELEASE_ARCHIVE:-}"
PREVIOUS_RELEASE_SHA256_FILE="${SELFHOST_SMOKE_PREVIOUS_RELEASE_SHA256_FILE:-${PREVIOUS_RELEASE_ARCHIVE}.sha256}"
PREVIOUS_RELEASE_SIGNATURE_FILE="${SELFHOST_SMOKE_PREVIOUS_RELEASE_SIGNATURE_FILE:-${PREVIOUS_RELEASE_SHA256_FILE}.sig}"
if [[ -n "$PREVIOUS_RELEASE_ARCHIVE" ]]; then
  previous_metadata="$(inspect_release_archive "$PREVIOUS_RELEASE_ARCHIVE" "$PREVIOUS_RELEASE_SHA256_FILE" "$PREVIOUS_RELEASE_SIGNATURE_FILE")" ||
    fail "the supplied previous release artifact did not pass verification"
  IFS=$'\t' read -r OLD_VERSION OLD_SOURCE_REVISION ARCHIVED_BACKEND_IMAGE <<<"$previous_metadata"
  PREVIOUS_BACKEND_IMAGE="${PREVIOUS_BACKEND_IMAGE:-$ARCHIVED_BACKEND_IMAGE}"
  [[ -z "$RELEASE_ARCHIVE" || "$PREVIOUS_BACKEND_IMAGE" == "$ARCHIVED_BACKEND_IMAGE" ]] ||
    fail "candidate release drill must run the published predecessor backend image"
  NEW_VERSION="$(latest_changelog_version)" || fail "could not select the current release-smoke target version"
  version_is_newer "$NEW_VERSION" "$OLD_VERSION" ||
    fail "the selected previous release is not older than the current changelog"
  OLD_ARCHIVE="$PREVIOUS_RELEASE_ARCHIVE"
  OLD_SHA256_FILE="$PREVIOUS_RELEASE_SHA256_FILE"
  OLD_SIGNATURE_FILE="$PREVIOUS_RELEASE_SIGNATURE_FILE"
else
  OLD_VERSION="$(latest_changelog_version 1)" || fail "could not select a changelog-backed synthetic predecessor"
  OLD_SOURCE_REVISION="$REVISION"
  NEW_VERSION="$(latest_changelog_version)" || fail "could not select the current release-smoke target version"
  PREVIOUS_BACKEND_IMAGE="${PREVIOUS_BACKEND_IMAGE:-$BACKEND_IMAGE}"
  OLD_ARCHIVE="${ARTIFACT_DIR}/chronicle-selfhost-${OLD_VERSION}.tar.gz"
  OLD_SHA256_FILE="${OLD_ARCHIVE}.sha256"
fi
NEW_ARCHIVE="${ARTIFACT_DIR}/chronicle-selfhost-${NEW_VERSION}.tar.gz"
NEW_SHA256_FILE="${NEW_ARCHIVE}.sha256"
NEW_SIGNATURE_FILE="${NEW_SHA256_FILE}.sig"
if [[ -n "$RELEASE_ARCHIVE" ]]; then
  NEW_ARCHIVE="$RELEASE_ARCHIVE"
  NEW_SHA256_FILE="$RELEASE_SHA256_FILE"
  NEW_SIGNATURE_FILE="$RELEASE_SIGNATURE_FILE"
  SMOKE_ARCHIVE_HASH_FIELD="$(verify_release_signature "$NEW_SHA256_FILE" "$NEW_SIGNATURE_FILE" "${CHRONICLE_RELEASE_VERIFY_KEY:-$ROOT_DIR/selfhost/release-signing.pub}")" ||
    fail "candidate signature does not match the release verification key"
fi

printf 'Preparing a verified previous release and a source-free current release bundle.\n'
if [[ -z "$PREVIOUS_RELEASE_ARCHIVE" ]]; then
"$BUILDER" \
  --version "v${OLD_VERSION}" \
  --source-revision "$REVISION" \
  --source-date-epoch "$SOURCE_DATE_EPOCH" \
  --backend-image "$BACKEND_IMAGE" \
  --frontend-image "$FRONTEND_IMAGE" \
  --caddy-image "$CADDY_IMAGE" \
  --output-dir "$ARTIFACT_DIR" >/dev/null
fi
if [[ -z "$RELEASE_ARCHIVE" ]]; then
"$BUILDER" \
  --version "v${NEW_VERSION}" \
  --source-revision "$REVISION" \
  --source-date-epoch "$SOURCE_DATE_EPOCH" \
  --backend-image "$BACKEND_IMAGE" \
  --frontend-image "$FRONTEND_IMAGE" \
  --caddy-image "$CADDY_IMAGE" \
  --output-dir "$ARTIFACT_DIR" >/dev/null
fi
old_metadata="$(inspect_release_archive "$OLD_ARCHIVE" "$OLD_SHA256_FILE" "${OLD_SIGNATURE_FILE:-}")" ||
  fail "previous release artifact failed checksum or inventory verification"
IFS=$'\t' read -r OLD_VERSION OLD_SOURCE_REVISION ARCHIVED_BACKEND_IMAGE <<<"$old_metadata"
if [[ -z "${SELFHOST_SMOKE_PREVIOUS_BACKEND_IMAGE:-}" ]]; then
  PREVIOUS_BACKEND_IMAGE="${PREVIOUS_BACKEND_IMAGE:-$ARCHIVED_BACKEND_IMAGE}"
fi
new_metadata="$(inspect_release_archive "$NEW_ARCHIVE" "$NEW_SHA256_FILE")" ||
  fail "current release artifact failed checksum or inventory verification"
IFS=$'\t' read -r ARCHIVED_NEW_VERSION NEW_SOURCE_REVISION _ <<<"$new_metadata"
[[ "$ARCHIVED_NEW_VERSION" == "$NEW_VERSION" ]] || fail "current release archive has the wrong version"
[[ "$NEW_SOURCE_REVISION" == "$REVISION" ]] || fail "current release archive has the wrong source revision"
if [[ -n "$PREVIOUS_RELEASE_ARCHIVE" && "$OLD_SOURCE_REVISION" == "$NEW_SOURCE_REVISION" ]]; then
  fail "the previous release archive does not have a distinct source revision"
fi
previous_release_evidence="$(python3 - "$BUILDER" "$OLD_ARCHIVE" <<'PY_PREDECESSOR_EVIDENCE'
from pathlib import Path
import runpy
import sys
helpers = runpy.run_path(sys.argv[1])
for key, value in helpers["smoke_predecessor_evidence"](Path(sys.argv[2])).items():
    print(f"{key}={value}")
PY_PREDECESSOR_EVIDENCE
)"
/bin/mkdir "${RUN_DIR}/extracted"
# -p keeps the archive's 0755 directories under this script's umask 077; config-guard runs
# as the postgres uid and must search the bind-mounted selfhost/ directory.
tar -xzpf "$OLD_ARCHIVE" -C "${RUN_DIR}/extracted"
OLD_BUNDLE="${RUN_DIR}/extracted/chronicle-selfhost-${OLD_VERSION}/selfhost"
NEW_BUNDLE="${ARTIFACT_DIR}/chronicle-selfhost-${NEW_VERSION}/selfhost"
if [[ -n "$RELEASE_ARCHIVE" ]]; then
  /bin/mkdir -p "$ARTIFACT_DIR"
  tar -xzpf "$NEW_ARCHIVE" -C "$ARTIFACT_DIR"
fi
BUNDLE="$OLD_BUNDLE"

RUN_DIR="$RUN_DIR" \
OLD_BUNDLE="$OLD_BUNDLE" \
NEW_BUNDLE="$NEW_BUNDLE" \
RUNTIME_BACKEND_IMAGE="$BACKEND_IMAGE" \
RUNTIME_PREVIOUS_BACKEND_IMAGE="$PREVIOUS_BACKEND_IMAGE" \
RUNTIME_FRONTEND_IMAGE="$FRONTEND_IMAGE" \
RUNTIME_CADDY_IMAGE="$CADDY_IMAGE" \
RUNTIME_BACKUP_IMAGE="$BACKUP_IMAGE" \
RELEASE_BUILDER="$BUILDER" \
RELEASE_ARCHIVE_SUPPLIED="${RELEASE_ARCHIVE:+true}" \
PREVIOUS_RELEASE_SUPPLIED="${PREVIOUS_RELEASE_ARCHIVE:+true}" \
ENABLE_MONITORING="$MONITORING" \
SMOKE_PASSWORD="$SMOKE_PASSWORD" \
DISK_SMOKE_VOLUME_BYTES="$DISK_SMOKE_VOLUME_BYTES" \
python3 - <<'PY'
from pathlib import Path
import hashlib
import json
import os
import secrets
import socket
import subprocess
import runpy

run_dir = Path(os.environ["RUN_DIR"])
old_bundle = Path(os.environ["OLD_BUNDLE"])
new_bundle = Path(os.environ["NEW_BUNDLE"])
candidate_supplied = os.environ.get("RELEASE_ARCHIVE_SUPPLIED") == "true"
if candidate_supplied:
    runpy.run_path(os.environ["RELEASE_BUILDER"])["require_smoke_images"](
        new_bundle.parent,
        {name: os.environ[key] for name, key in
         (("backend", "RUNTIME_BACKEND_IMAGE"), ("frontend", "RUNTIME_FRONTEND_IMAGE"), ("caddy", "RUNTIME_CADDY_IMAGE"))},
        os.environ["RUNTIME_BACKUP_IMAGE"])

# A real previous release runs its own web images: its compose and cert-init predate the
# current images (10.3 keys are root 0600; current Caddy runs as uid 10001). Synthetic
# previous bundles carry placeholder digests, so they keep the current local images.
previous_web = {
    "SELFHOST_FRONTEND_IMAGE": os.environ["RUNTIME_FRONTEND_IMAGE"],
    "CADDY_IMAGE": os.environ["RUNTIME_CADDY_IMAGE"],
}
if os.environ.get("PREVIOUS_RELEASE_SUPPLIED") == "true":
    for line in (old_bundle / ".env.example").read_text(encoding="utf-8").splitlines():
        key, sep, value = line.partition("=")
        if sep and key in previous_web:
            previous_web[key] = value


def available_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


ports: list[int] = []
while len(ports) < 4:
    candidate = available_port()
    if candidate not in ports:
        ports.append(candidate)
http_port, internal_port, grafana_port, update_port = ports


def free_subnet() -> str:
    # Like the ports: the default CHRONICLE_SUBNET may already belong to another stack here.
    import ipaddress

    ids = subprocess.run(["docker", "network", "ls", "-q"], check=True, capture_output=True, text=True).stdout.split()
    held = [
        ipaddress.ip_network(config["Subnet"], strict=False)
        for network in json.loads(subprocess.run(["docker", "network", "inspect", *ids], check=True, capture_output=True, text=True).stdout)
        for config in (network.get("IPAM") or {}).get("Config") or []
        if config.get("Subnet") and ":" not in config["Subnet"]
    ]
    start = secrets.randbelow(256)
    for third in [(start + offset) % 256 for offset in range(256)]:
        candidate = ipaddress.ip_network(f"10.253.{third}.0/24")
        if not any(candidate.overlaps(other) for other in held):
            return str(candidate)
    raise SystemExit("no free 10.253.x.0/24 subnet for the smoke project network")


smoke_subnet = free_subnet()
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
    "DOMAIN": "selfhost.study-host.org",
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
    "BACKEND_IMAGE": os.environ["RUNTIME_PREVIOUS_BACKEND_IMAGE"],
    **previous_web,
    # A 10.3 internal dashboard signs in through the built-in login; the update migrates it
    # to the password-only login (release.migrate_dashboard_login).
    "TESTING_LOGIN_ENABLED": "true",
    "REQUIRE_MFA": "false",
    "BACKUP_STARTUP_TIMEOUT_SECONDS": "180",
}
runtime_images = {
    "BACKEND_IMAGE": os.environ["RUNTIME_BACKEND_IMAGE"],
    "SELFHOST_FRONTEND_IMAGE": os.environ["RUNTIME_FRONTEND_IMAGE"],
    "CADDY_IMAGE": os.environ["RUNTIME_CADDY_IMAGE"],
}


def use_runtime_images(bundle: Path, backend_image: str, web: dict[str, str]) -> None:
    runtime_images["BACKEND_IMAGE"] = backend_image
    runtime_images.update(web)
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


# The new bundle already carries these digests (no-op there); the previous release is
# pointed at its runtime images after its checksum and source-free checks.
use_runtime_images(old_bundle, os.environ["RUNTIME_PREVIOUS_BACKEND_IMAGE"], previous_web)
if not candidate_supplied:
    use_runtime_images(
        new_bundle,
        os.environ["RUNTIME_BACKEND_IMAGE"],
        {
            "SELFHOST_FRONTEND_IMAGE": os.environ["RUNTIME_FRONTEND_IMAGE"],
            "CADDY_IMAGE": os.environ["RUNTIME_CADDY_IMAGE"],
        },
    )
# Fresh installs keep the shipped volume; upgrades reuse the capped predecessor volume.
compose = old_bundle / "docker-compose.yml"
text = compose.read_text()
volume_start = text.index("\nvolumes:\n")
marker = "\n  postgres_data:\n"
if marker not in text[volume_start:]:
    raise SystemExit("published predecessor has an unsupported database volume definition")
cap = os.environ["DISK_SMOKE_VOLUME_BYTES"]
text = text[:volume_start] + text[volume_start:].replace(marker, marker + '    driver: local\n    driver_opts:\n      type: tmpfs\n      device: tmpfs\n      o: "size=' + cap + ',mode=0700"\n', 1)
compose.write_text(text)
manifest_path = old_bundle.parent / "release-manifest.json"
manifest = json.loads(manifest_path.read_text())
manifest["files"]["selfhost/docker-compose.yml"] = hashlib.sha256(compose.read_bytes()).hexdigest()
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

backup_image = os.environ["RUNTIME_BACKUP_IMAGE"]
if backup_image and not candidate_supplied:
    overlay = new_bundle / "overlays/backups.yml"
    text = overlay.read_text(encoding="utf-8")
    pins = [line for line in text.splitlines()
            if line.strip().startswith("image:") and "chronicle-selfhost-backup" in line]
    if len(pins) != 1:
        raise SystemExit(f"expected one backup image pin, found {len(pins)}")
    overlay.write_text(text.replace(pins[0], pins[0].split("image:")[0] + "image: " + backup_image), encoding="utf-8")
    manifest_path = new_bundle.parent / "release-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["files"]["selfhost/overlays/backups.yml"] = hashlib.sha256(overlay.read_bytes()).hexdigest()
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

lines = (old_bundle / ".env.example").read_text(encoding="utf-8").splitlines()
rendered: list[str] = []
seen: set[str] = set()
for line in lines:
    if "=" in line and not line.lstrip().startswith("#"):
        key = line.split("=", 1)[0]
        if key in values:
            line = f"{key}={values[key]}"
            seen.add(key)
        elif key == "CHRONICLE_SUBNET":
            line = f"{key}={smoke_subnet}"
            seen.add(key)
        elif key == "POSTGRES_MIN_WAL_SIZE":
            line = f"{key}=32MB"
        elif key == "POSTGRES_MAX_WAL_SIZE":
            line = f"{key}=64MB"
    rendered.append(line)
missing = sorted(set(values) - seen)
if missing:
    raise SystemExit(f"missing expected .env keys: {', '.join(missing)}")
# A previous release without the setting still hands it to `upgrade` as an operator value.
if "CHRONICLE_SUBNET" not in seen:
    rendered.append(f"CHRONICLE_SUBNET={smoke_subnet}")
rendered.append("BACKUP_STORAGE_ENCRYPTION_WAIVER=synthetic-release-smoke-fixture-no-study-data")
env_path = old_bundle / ".env"
env_path.write_text("\n".join(rendered) + "\n", encoding="utf-8")
env_path.chmod(0o600)
(run_dir / "smoke-metadata.txt").write_text(
    f"project={project}\n"
    f"http_port={http_port}\n"
    f"internal_port={internal_port}\n"
    f"grafana_port={grafana_port}\n"
    f"update_port={update_port}\n",
    encoding="utf-8",
)
PY

# The metadata contains no secrets and uses shell-safe generated values.
project=""
http_port=""
internal_port=""
grafana_port=""
update_port=""
# shellcheck disable=SC1090
source "${RUN_DIR}/smoke-metadata.txt"
[[ -n "$project" && -n "$http_port" && -n "$internal_port" && -n "$grafana_port" && -n "$update_port" ]] ||
  fail "generated smoke metadata is incomplete"
PROJECT="$project"
# The daemon keeps only recent events; record this project's and every network change for diagnosis.
docker events --filter "label=com.docker.compose.project=$project" --format '{{json .}}' >"${RUN_DIR}/docker-events.jsonl" 2>&1 &
DOCKER_EVENT_PIDS="$!"
docker events --filter type=network --format '{{json .}}' >"${RUN_DIR}/docker-network-events.jsonl" 2>&1 &
DOCKER_EVENT_PIDS+=" $!"

# The current-side bundle is reached only through the old release's verified update path.
# Local fixtures are repacked; downloaded candidates keep their original signed bytes.
new_bundle_root="chronicle-selfhost-${NEW_VERSION}"
if [[ -z "$RELEASE_ARCHIVE" ]]; then
tar -czf "$NEW_ARCHIVE" -C "$ARTIFACT_DIR" "$new_bundle_root"
(
  cd "$ARTIFACT_DIR"
  sha256sum "$(basename "$NEW_ARCHIVE")" >"$(basename "$NEW_SHA256_FILE")"
)
repacked_metadata="$(inspect_release_archive "$NEW_ARCHIVE" "$NEW_SHA256_FILE")" ||
  fail "current release archive failed verification after local-image substitution"
IFS=$'\t' read -r REPACKED_VERSION REPACKED_REVISION _ <<<"$repacked_metadata"
[[ "$REPACKED_VERSION" == "$NEW_VERSION" && "$REPACKED_REVISION" == "$REVISION" ]] ||
  fail "repacked current release archive has the wrong identity"
fixture_key="${RUN_DIR}/release-fixture-signing-key"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_key"
# Released bundles ship this key 0644; cp under umask 077 would leave it unreadable to containers.
install -m 0644 "$fixture_key.pub" "$OLD_BUNDLE/release-signing.pub"
python3 - "$BUILDER" "$OLD_BUNDLE" <<'PY_FIXTURE_KEY'
from pathlib import Path
import json
import runpy
import sys
builder, bundle = map(Path, sys.argv[1:])
helpers = runpy.run_path(str(builder))
manifest_path = bundle.parent / 'release-manifest.json'
manifest = json.loads(manifest_path.read_text())
manifest['files']['selfhost/release-signing.pub'] = helpers['sha256'](bundle / 'release-signing.pub')
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PY_FIXTURE_KEY
release_signer=$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT_DIR/selfhost" python3 -c \
  'from chronicle_ops.release import RELEASE_SIGNER; print(RELEASE_SIGNER)')
ssh-keygen -Y sign -n "$release_signer" -f "$fixture_key" "$NEW_SHA256_FILE"
SMOKE_ARCHIVE_HASH_FIELD="$(verify_release_signature "$NEW_SHA256_FILE" "$NEW_SIGNATURE_FILE" "$fixture_key.pub")"
else
[[ -z "$PREVIOUS_RELEASE_ARCHIVE" ]] || RELEASE_ARCHIVE_SHA256="$(sha256sum "$NEW_ARCHIVE" | awk '{print $1}')"
fi
UPDATE_FIXTURE_DIR="${RUN_DIR}/release-fixture"
/bin/mkdir -m 0700 "$UPDATE_FIXTURE_DIR"
/bin/cp "$NEW_ARCHIVE" "$UPDATE_FIXTURE_DIR/"
/bin/cp "$NEW_SHA256_FILE" "$UPDATE_FIXTURE_DIR/$new_bundle_root.tar.gz.sha256"
/bin/cp "$NEW_SIGNATURE_FILE" "$UPDATE_FIXTURE_DIR/$new_bundle_root.tar.gz.sha256.sig"
RELEASES_URL="http://127.0.0.1:${update_port}/latest.json"
RELEASE_FIXTURE_DIR="$UPDATE_FIXTURE_DIR" \
RELEASE_PORT="$update_port" \
RELEASE_VERSION="$NEW_VERSION" \
python3 - <<'PY'
import json
import os
from pathlib import Path

name = f"chronicle-selfhost-{os.environ['RELEASE_VERSION']}.tar.gz"
base = f"http://127.0.0.1:{os.environ['RELEASE_PORT']}"
payload = {
    "tag_name": f"v{os.environ['RELEASE_VERSION']}",
    "assets": [
        {"name": name, "browser_download_url": f"{base}/{name}"},
        {"name": f"{name}.sha256", "browser_download_url": f"{base}/{name}.sha256"},
        {"name": f"{name}.sha256.sig", "browser_download_url": f"{base}/{name}.sha256.sig"},
    ],
    "body": "Synthetic loopback-only release smoke fixture.",
}
(Path(os.environ["RELEASE_FIXTURE_DIR"]) / "latest.json").write_text(
    json.dumps(payload), encoding="utf-8"
)
PY
python3 -m http.server --bind 127.0.0.1 "$update_port" --directory "$UPDATE_FIXTURE_DIR" \
  >"${RUN_DIR}/update-server.log" 2>&1 &
UPDATE_SERVER_PID=$!
update_server_ready=false
for _ in {1..20}; do
  if bounded_curl -fsS "$RELEASES_URL" >/dev/null; then
    update_server_ready=true
    break
  fi
  sleep 0.25
done
[[ "$update_server_ready" == true ]] || fail "loopback update fixture did not become ready"

# Stands in for the operator's TLS proxy: behind-proxy `verify` requires plain HTTP on the
# public name to redirect to HTTPS. curl reads $CURL_HOME/.curlrc, so only the fixture's
# public name on port 80 reaches this loopback listener; product code is unchanged.
SMOKE_PUBLIC_HOST=selfhost.study-host.org
python3 - "${RUN_DIR}/redirect-port" "$SMOKE_PUBLIC_HOST" >"${RUN_DIR}/redirect-server.log" 2>&1 <<'REDIRECT' &
import http.server
import os
import sys

port_file, host = sys.argv[1], sys.argv[2]


class Redirect(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(301)
        self.send_header("Location", f"https://{host}{self.path}")
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_HEAD = do_GET


server = http.server.HTTPServer(("127.0.0.1", 0), Redirect)
with open(port_file + ".tmp", "w", encoding="utf-8") as handle:
    handle.write(str(server.server_port))
os.replace(port_file + ".tmp", port_file)
server.serve_forever()
REDIRECT
REDIRECT_SERVER_PID=$!
for _ in {1..20}; do
  [[ -s "${RUN_DIR}/redirect-port" ]] && break
  sleep 0.25
done
[[ -s "${RUN_DIR}/redirect-port" ]] || fail "loopback HTTPS-redirect fixture did not become ready"
/bin/mkdir -m 0700 "${RUN_DIR}/curl-home"
printf 'connect-to = %s:80:127.0.0.1:%s\n' "$SMOKE_PUBLIC_HOST" "$(<"${RUN_DIR}/redirect-port")" \
  >"${RUN_DIR}/curl-home/.curlrc"
# Host checks use a real TLS-terminating HAProxy; remote acceptance runs separately below.
mkdir -p "$RUN_DIR/proxy-fixture"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=selfhost-smoke-CA \
  -keyout "$RUN_DIR/proxy-fixture/ca.key" -out "$RUN_DIR/proxy-fixture/ca.crt" \
  -addext basicConstraints=critical,CA:TRUE >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$SMOKE_PUBLIC_HOST" \
  -keyout "$RUN_DIR/proxy-fixture/lb.key" -out "$RUN_DIR/proxy-fixture/lb.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\n' "$SMOKE_PUBLIC_HOST" >"$RUN_DIR/proxy-fixture/lb.ext"
openssl x509 -req -in "$RUN_DIR/proxy-fixture/lb.csr" -CA "$RUN_DIR/proxy-fixture/ca.crt" \
  -CAkey "$RUN_DIR/proxy-fixture/ca.key" -CAcreateserial -days 2 \
  -extfile "$RUN_DIR/proxy-fixture/lb.ext" -out "$RUN_DIR/proxy-fixture/lb.crt" >/dev/null 2>&1
cat "$RUN_DIR/proxy-fixture/lb.crt" "$RUN_DIR/proxy-fixture/lb.key" >"$RUN_DIR/proxy-fixture/lb.pem"
proxy_port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
cat >"$RUN_DIR/proxy-fixture/lb.cfg" <<EOF
global
    maxconn 128
defaults
    mode http
    timeout connect 5s
    timeout client 300s
    timeout server 300s
frontend public
    bind 127.0.0.1:$proxy_port ssl crt /fixture/lb.pem
    http-request set-header X-Forwarded-For %[src]
    http-request set-header X-Forwarded-Proto https
    default_backend chronicle
backend chronicle
    server web 127.0.0.1:$http_port
EOF
TLS_PROXY_CONTAINER="${PROJECT}-tls-fixture"
docker run -d --name "$TLS_PROXY_CONTAINER" --network host --read-only --cap-drop ALL \
  --user "$(id -u):$(id -g)" -v "$RUN_DIR/proxy-fixture:/fixture:ro" --entrypoint haproxy \
  "$(sed -n '/image: tecnativa\/docker-socket-proxy/s/^    image: //p' "$NEW_BUNDLE/overlays/monitoring.yml")" \
  -W -db -f /fixture/lb.cfg >/dev/null
printf 'connect-to = %s:443:127.0.0.1:%s\ncacert = %s\n' "$SMOKE_PUBLIC_HOST" "$proxy_port" \
  "$RUN_DIR/proxy-fixture/ca.crt" >>"${RUN_DIR}/curl-home/.curlrc"
export CURL_HOME="${RUN_DIR}/curl-home"

fresh_candidate_install() { # <clean candidate selfhost directory>
  (
    cd "$1"
    [[ ! -e .env ]] || fail "fresh candidate already has deployment settings"
    unset CADDY_TRUSTED_PROXIES POOL_ALLOWED_IPS DASHBOARD_ALLOWED_IPS DASHBOARD_BASE_URL PUBLIC_HTTP_ENABLED
    local monitoring_answer=n
    [[ "$MONITORING" != true ]] || monitoring_answer=y
    # Behind-proxy mode, public hostname, then defaults for binds, origin and LB contract.
    local -a answers=("" "$SMOKE_PUBLIC_HOST" "" "" "" "" "" "" "" "" "" "" "" ""
                     "$SMOKE_PASSWORD" "$SMOKE_PASSWORD" n "$monitoring_answer")
    [[ "$MONITORING" != true ]] || answers+=("" "" "" "")
    printf '%s\n' "${answers[@]}" | COMPOSE_PROJECT_NAME="$PROJECT" HTTP_PORT="$http_port" \
      HTTP_BIND=127.0.0.1 INTERNAL_BIND=127.0.0.1 GRAFANA_BIND=127.0.0.1 \
      INTERNAL_PORT="$internal_port" GRAFANA_PORT="$grafana_port" ./chronicle setup
    START_WAIT_TIMEOUT_SECONDS=300 ./chronicle up
    printf '%s\n' "$SMOKE_PASSWORD" | ./chronicle verify --dashboard-password
  )
}

printf 'Installing the candidate with setup, up and verify in a clean deployment.\n'
mkdir "$RUN_DIR/fresh"
tar -xzpf "$NEW_ARCHIVE" -C "$RUN_DIR/fresh"
FRESH_BUNDLE="$RUN_DIR/fresh/chronicle-selfhost-${NEW_VERSION}/selfhost"
BUNDLE="$FRESH_BUNDLE"
PROJECT="${project}-fresh"
fresh_candidate_install "$FRESH_BUNDLE"
fresh_install=pass
(cd "$FRESH_BUNDLE" && docker compose down -v --remove-orphans)
BUNDLE="$OLD_BUNDLE"
PROJECT="$project"

for candidate_bundle in "$OLD_BUNDLE" "$NEW_BUNDLE"; do
  (
    cd "$candidate_bundle"
    config_report="$(./verify-config.sh 2>&1)" ||
      { grep -F FAIL <<<"$config_report" >&2; fail "verify-config failed: $candidate_bundle"; }
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
[[ "$PROJECT" == chronicle-release-smoke-* ]] || fail "capped volume requires the isolated smoke project"
disk_volume="${PROJECT}_postgres_data"
! docker volume inspect "$disk_volume" >/dev/null 2>&1 || fail "smoke database volume already exists"
docker volume create --label "com.docker.compose.project=$PROJECT" \
  --label com.docker.compose.volume=postgres_data --driver local --opt type=tmpfs \
  --opt device=tmpfs --opt "o=size=$DISK_SMOKE_VOLUME_BYTES,mode=0700" "$disk_volume" >/dev/null
postgres_image=$(docker compose config --format json | jq -er '.services.postgres.image')
# A live reference keeps the bounded tmpfs mounted across database stops and recreations.
DISK_VOLUME_KEEPER=$(timeout "$DISK_DRILL_MAX_SECONDS" docker run --rm -d --user postgres \
  --read-only --cap-drop ALL --security-opt no-new-privileges --network none \
  --memory 8m --pids-limit 8 --entrypoint /bin/sleep \
  --mount "type=volume,source=$disk_volume,target=/hold" "$postgres_image" infinity)
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

printf 'Enrolling a real Android client and writing every upload type before the transition.\n'
cat "$RUN_DIR/proxy-fixture/ca.crt" \
  "${OLD_BUNDLE}/tls/$( [[ -f "$OLD_BUNDLE/tls/internal-ca.crt" ]] && printf internal-ca.crt || printf internal-cert.pem )" \
  >"$RUN_DIR/client-ca.crt"
printf '%s\n' "$SMOKE_PASSWORD" | python3 "$ROOT_DIR/tests/deployment/selfhost-client.py" \
  --public "https://$SMOKE_PUBLIC_HOST" --management "https://127.0.0.1:$internal_port" \
  --ca "$RUN_DIR/client-ca.crt" --resolve-public "127.0.0.1:$proxy_port" --records "$RUN_DIR/client.json" \
  --seed-only
assert_upload_rows() {
  python3 "$ROOT_DIR/tests/deployment/selfhost-client.py" --assert-db --project "$PROJECT" --records "$RUN_DIR/client.json"
}
assert_upload_rows
# A persistent installation also carries old data through each supported transition.
docker compose exec -T postgres /bin/bash -ceu \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL_AGED'
CREATE TABLE upgrade_smoke_aged_data AS
SELECT id, now() - interval '6 months' AS collected_at, repeat(md5(id::text), 1024) AS payload
FROM generate_series(1,1024) AS id;
SQL_AGED

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
BUNDLE="$OLD_BUNDLE"
cd "$OLD_BUNDLE"
# Exported values have higher Compose interpolation precedence than .env. Poison the
# high-impact controls deliberately: the upgrade command must isolate them and use only the
# validated old/new release files. Success proves it did not select the restore profile,
# another project, an untrusted Compose file, or an inherited image override.
DASHBOARD_PASSWORD="$SMOKE_PASSWORD" UPGRADE_WAIT_TIMEOUT_SECONDS=300 \
COMPOSE_FILE="${RUN_DIR}/must-not-be-used.yml" COMPOSE_PROFILES=restore \
COMPOSE_PROJECT_NAME=must-not-be-used BACKEND_IMAGE=must-not-be-used:latest \
CHRONICLE_RELEASES_URL="$RELEASES_URL" ./chronicle update
NEW_BUNDLE="${RUN_DIR}/extracted/chronicle-selfhost-${NEW_VERSION}/selfhost"
[[ -x "$NEW_BUNDLE/chronicle" ]] || fail "verified update did not extract the current release operator"
BUNDLE="$NEW_BUNDLE"
cd "$NEW_BUNDLE"

upgrade_line="$(
  OLD_BUNDLE="$OLD_BUNDLE" NEW_BUNDLE="$NEW_BUNDLE" \
  EXPECTED_VERSION="$NEW_VERSION" \
  EXPECTED_OLD_VERSION="$OLD_VERSION" \
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
if payload.get("from", {}).get("version") != os.environ["EXPECTED_OLD_VERSION"]:
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
assert_upload_rows

printf 'Changing the sentinel, then exercising the documented schema-safe rollback.\n'
docker compose exec -T postgres /bin/bash -ceu \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -qc "UPDATE upgrade_smoke_sentinel SET marker = '\''after-upgrade'\'' WHERE id = 1"'
[[ "$(sentinel_marker)" == after-upgrade ]] || fail "post-upgrade sentinel mutation failed"
PRE_UPGRADE_SHA256="$(sha256sum "$PRE_UPGRADE_BACKUP" | awk '{print $1}')"
[[ "$PRE_UPGRADE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "pre-upgrade backup SHA-256 is unavailable"
./chronicle rollback --yes --from "$OLD_BUNDLE" --trusted-sha256="$PRE_UPGRADE_SHA256" \
  "$PRE_UPGRADE_CONTAINER_PATH"
[[ ! -e "${OLD_BUNDLE}/.chronicle-restore.lock" ]] || fail "rollback restore lock was not released"

BUNDLE="$OLD_BUNDLE"
cd "$OLD_BUNDLE"
./chronicle up
verify_with_dashboard_password >/dev/null
[[ "$(sentinel_marker)" == before-upgrade ]] || fail "rollback did not restore pre-upgrade data"
assert_upload_rows

printf 'Starting the new release again to prove forward recovery after rollback.\n'
[[ ! -e "$NEW_BUNDLE/.env" ]] || fail "rollback did not retire candidate settings"
compgen -G "$OLD_BUNDLE/operator-receipts/.env.rollback-*" >/dev/null || fail "rollback settings were not preserved"
BUNDLE="$NEW_BUNDLE"
cd "$NEW_BUNDLE"
DASHBOARD_PASSWORD="$SMOKE_PASSWORD" UPGRADE_WAIT_TIMEOUT_SECONDS=300 \
  ./chronicle upgrade --from "$OLD_BUNDLE"
verify_with_dashboard_password >/dev/null
[[ "$(sentinel_marker)" == before-upgrade ]] || fail "forward recovery lost restored data"
assert_upload_rows

printf 'Exercising the full Android client against the candidate after forward recovery.\n'
# The upgrade keeps TLS material in the predecessor's state directory.
cat "$RUN_DIR/proxy-fixture/ca.crt" \
  "${OLD_BUNDLE}/tls/$( [[ -f "$OLD_BUNDLE/tls/internal-ca.crt" ]] && printf internal-ca.crt || printf internal-cert.pem )" \
  >"$RUN_DIR/client-candidate-ca.crt"
candidate_client=(python3 "$ROOT_DIR/tests/deployment/selfhost-client.py"
  --public "https://$SMOKE_PUBLIC_HOST" --management "https://127.0.0.1:$internal_port"
  --ca "$RUN_DIR/client-candidate-ca.crt" --resolve-public "127.0.0.1:$proxy_port"
  --enrollment-credentials "$RUN_DIR/enrollment-credentials.json")
printf '%s\n' "$SMOKE_PASSWORD" | "${candidate_client[@]}" --records "$RUN_DIR/client-candidate.json"
python3 "$ROOT_DIR/tests/deployment/selfhost-client.py" --assert-db --project "$PROJECT" --records "$RUN_DIR/client-candidate.json"
# The upload probes add rows for the same participant, so they run after its receipt is asserted.
printf '%s\n' "$SMOKE_PASSWORD" | "${candidate_client[@]}" --records "$RUN_DIR/client-candidate.json" \
  --upload-security-report "$RUN_DIR/upload-security"

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
  monitoring_ca="$(PYTHONPATH="$ROOT_DIR/selfhost" python3 - "$BUNDLE" <<'PY_MONITORING_CA'
from pathlib import Path
import sys
from chronicle_ops.release import read_env, value

bundle = Path(sys.argv[1])
state = (bundle / (value(read_env(bundle / ".env"), "CHRONICLE_STATE_DIR", ".") or ".")).resolve()
print(state / "tls/monitoring.crt")
PY_MONITORING_CA
)"
  bounded_curl -fsS --cacert "$monitoring_ca" "https://127.0.0.1:${grafana_port}/api/health" | jq -e '.database == "ok"' >/dev/null
  monitoring_deadline=$((SECONDS + 60))
  monitoring_target_ready=false
  while (( SECONDS < monitoring_deadline )); do
    if docker compose exec -T grafana wget -T 10 -qO- http://victoriametrics:8428/api/v1/targets \
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
    if docker compose exec -T grafana wget -T 10 -qO- \
      'http://victoriametrics:8428/api/v1/query?query=up%7Bjob%3D%22chronicle-containers%22%7D%20%3D%3D%201' \
      >"${RUN_DIR}/vm-query.json" &&
      jq -e '.status == "success" and (.data.result | length >= 1)' "${RUN_DIR}/vm-query.json" >/dev/null; then
      monitoring_sample_ready=true
      break
    fi
    sleep 2
  done
  [[ "$monitoring_sample_ready" == true ]] || fail "VictoriaMetrics did not ingest the cAdvisor scrape result"
  BUNDLE="$BUNDLE" MONITORING_CA_FILE="$monitoring_ca" GRAFANA_PORT="$grafana_port" python3 - <<'PY'
from base64 import b64encode
import json
import os
from pathlib import Path
import time
import ssl
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
tls = ssl.create_default_context(cafile=os.environ["MONITORING_CA_FILE"])
# The self-signed monitoring certificate has no keyUsage; Python 3.13+ strict mode rejects it
# while browsers and curl accept it. Chain and hostname still verify.
tls.verify_flags &= ~ssl.VERIFY_X509_STRICT
base = f"https://127.0.0.1:{os.environ['GRAFANA_PORT']}"
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
            with urlopen(request, timeout=5, context=tls) as response:
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
rules = json.loads((Path(os.environ["BUNDLE"]) / "monitoring/grafana-alerting/rules.yml").read_text())
login_rule = next(rule for group in rules["groups"] for rule in group["rules"] if rule["uid"] == "failed-login-spike")
request = Request(base + "/api/ds/query", data=json.dumps({
    "queries": [login_rule["data"][0]["model"]], "from": "now-15m", "to": "now"
}).encode(), headers={"Authorization": f"Basic {authorization}", "Content-Type": "application/json"})
with urlopen(request, timeout=10, context=tls) as response:
    result = json.load(response)["results"]["A"]
if result.get("error") or not any(field["type"] == "number" for frame in result.get("frames", [])
                                  for field in frame["schema"]["fields"]):
    raise SystemExit("Grafana password alert query did not return a numeric failure count")
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
if [[ -n "$BACKUP_IMAGE" ]]; then
  printf 'Waiting for the backup restore self-check.\n'
  selfcheck_deadline=$((SECONDS + 600))
  until docker logs "$backup_container" 2>&1 | grep -F 'Restore self-check OK' >/dev/null; do
    ! docker logs "$backup_container" 2>&1 | grep -F 'Restore self-check FAIL' >&2 ||
      fail "backup restore self-check failed"
    ((SECONDS < selfcheck_deadline)) || fail "backup restore self-check did not finish"
    sleep 5
  done
fi
verify_with_dashboard_password >/dev/null

printf 'Restoring the newest generated dump into the isolated database.\n'
restore_started=$SECONDS
python3 "$ROOT_DIR/tests/deployment/selfhost-client.py" --capture-db --project "$PROJECT" --records "$RUN_DIR/client.json"
CLEAN_RESTORE_SHA256="$(sha256sum "${OLD_BUNDLE}/backups/last/chronicle-latest.sql.gz" | awk '{print $1}')"
[[ "$CLEAN_RESTORE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "clean restore SHA-256 is unavailable"
# Freeze the selected dump before writing a marker that must disappear on restoration.
CLEAN_RESTORE_FILE="${OLD_BUNDLE}/backups/clean-restore-smoke.sql.gz"
cp "${OLD_BUNDLE}/backups/last/chronicle-latest.sql.gz" "$CLEAN_RESTORE_FILE"
assert_upload_rows
docker compose exec -T postgres /bin/bash -ceu \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL_MARKER'
INSERT INTO upgrade_smoke_sentinel (id, marker) VALUES (2, 'after-clean-backup');
SQL_MARKER
./chronicle restore /backups/clean-restore-smoke.sql.gz --yes --trusted-sha256="$CLEAN_RESTORE_SHA256"
assert_upload_rows
post_backup_marker="$(docker compose exec -T postgres /bin/bash -ceu \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -qAt -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT count(*) FROM upgrade_smoke_sentinel WHERE id = 2"')"
[[ "$post_backup_marker" == 0 ]] || fail "clean restore retained the post-backup marker"
clean_restore_seconds=$((SECONDS - restore_started))
[[ ! -e "${OLD_BUNDLE}/.chronicle-restore.lock" ]] || fail "clean restore lock was not released"
verify_with_dashboard_password >/dev/null

printf 'Exhausting the size-capped synthetic database volume and checking recovery.\n'
[[ "$PROJECT" == chronicle-release-smoke-* ]] || fail "disk drill requires the isolated smoke project"
smoke_sql() {
  timeout "$DISK_DRILL_MAX_SECONDS" docker compose exec -T postgres /bin/bash -ceu \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -q -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1'
}
smoke_sql <<'SQL'
CREATE TABLE upgrade_smoke_disk_pressure (payload text);
ALTER TABLE upgrade_smoke_disk_pressure ALTER COLUMN payload SET STORAGE EXTERNAL;
SQL
# The named volume itself is capped; neither the host disk nor another project's data is filled.
# PGDATA's owner writes the file: root has no DAC_OVERRIDE in this container and is refused.
timeout "$DISK_DRILL_MAX_SECONDS" docker compose exec -T -u postgres postgres /bin/bash -ceu '
  total_kb=$(df -Pk "$PGDATA" | awk "NR==2 {print \$2}")
  [[ "$total_kb" =~ ^[0-9]+$ && "$total_kb" -le "$1" ]] || exit 91
  dd if=/dev/zero of="$PGDATA/.chronicle-disk-drill" bs=1M count="$2" 2>/tmp/disk-drill-error && exit 92
  grep -q "No space left on device" /tmp/disk-drill-error
' disk-drill "$((DISK_SMOKE_VOLUME_BYTES / 1024))" "$((DISK_SMOKE_VOLUME_BYTES / 1048576 + 1))" || fail "capped volume did not reach ENOSPC within its bound"
./chronicle doctor --json >"${RUN_DIR}/disk-full-doctor.json" || true
jq -e '[.checks[] | select(.check == "database-disk")] | length == 1 and .[0].status == "fail"' \
  "${RUN_DIR}/disk-full-doctor.json" >/dev/null || fail "default database disk warning did not fire"
if smoke_sql <<'SQL' >"${RUN_DIR}/disk-full-write.log" 2>&1
INSERT INTO upgrade_smoke_disk_pressure SELECT repeat('x', 65536) FROM generate_series(1, 128);
SQL
then
  fail "database writes unexpectedly succeeded on a full volume"
fi
docker compose exec -T -u postgres postgres /bin/bash -ceu 'rm -f "$PGDATA/.chronicle-disk-drill"'
./chronicle up --no-reconcile
docker compose ps --all -q | sort >"${RUN_DIR}/containers-before-reconcile"
CHRONICLE_RECONCILE_RUN=true ./chronicle up --no-reconcile
docker compose ps --all -q | sort >"${RUN_DIR}/containers-after-reconcile"
cmp -s "${RUN_DIR}/containers-before-reconcile" "${RUN_DIR}/containers-after-reconcile" ||
  fail "scheduled up recreated containers with unchanged configuration"
smoke_sql <<'SQL'
INSERT INTO upgrade_smoke_disk_pressure VALUES ('recovered');
DROP TABLE upgrade_smoke_disk_pressure;
SQL
[[ "$(sentinel_marker)" == before-upgrade ]] || fail "disk recovery lost the restored sentinel"
verify_with_dashboard_password >/dev/null
disk_full_recovery=pass

printf 'Checking dashboard response headers on the internal listener.\n'
dashboard_user="$(sed -n 's/^DASHBOARD_USER=//p' .env | head -1)"
curl_internal() { # curl_internal <path> [curl args...]
  local path="$1"; shift
  # A 2026.10.3 install keeps its own internal certificate and has no internal-ca.crt.
  bounded_curl -s --cacert "$RUN_DIR/client-candidate-ca.crt" "$@" "https://127.0.0.1:${internal_port}${path}"
}
shell_headers="$(curl_internal /chronicle/ -u "${dashboard_user}:${SMOKE_PASSWORD}" -D - -o /dev/null)"
grep -qi "^content-security-policy: default-src 'self'" <<<"$shell_headers" || fail "dashboard shell lacks a CSP"
grep -qi '^cache-control: no-cache' <<<"$shell_headers" || fail "dashboard shell is cacheable"
chunk_path="$(curl_internal /chronicle/ -u "${dashboard_user}:${SMOKE_PASSWORD}" | grep -oE '/chronicle/chunk-[a-z0-9]+\.js' | head -1)"
[[ -n "$chunk_path" ]] || fail "dashboard shell references no hashed chunk"
curl_internal "$chunk_path" -u "${dashboard_user}:${SMOKE_PASSWORD}" -D - -o /dev/null |
  grep -qi '^cache-control: public, max-age=31536000, immutable' || fail "hashed chunk is not immutable"

printf 'Proving API-created study and researcher permissions survive backend restart.\n'
printf '%s\n' "$SMOKE_PASSWORD" | python3 "$ROOT_DIR/tests/deployment/selfhost-client.py" \
  --create-study --management "https://127.0.0.1:$internal_port" \
  --ca "$RUN_DIR/client-ca.crt" --records "$RUN_DIR/persistent-study.json"
docker compose restart backend >/dev/null
wait_healthy_container "$(service_container backend)" 240 'Backend persistence restart'
printf '%s\n' "$SMOKE_PASSWORD" | python3 "$ROOT_DIR/tests/deployment/selfhost-client.py" \
  --assert-study --management "https://127.0.0.1:$internal_port" \
  --ca "$RUN_DIR/client-ca.crt" --records "$RUN_DIR/persistent-study.json"
study_restart_persistence=pass

printf 'Auditing the running self-host containers.\n'
# Every applicable container contract is a release gate. The audit owns explicit N/A cases
# for checks that genuinely do not apply to this configured self-host stack.
container_security_audit=unrun
run_container_security_audit "${RUN_DIR}/container-security.txt"

printf 'Proving the TDE data volume is unreadable without its keyring.\n'
postgres_query() {
  docker compose exec -T postgres /bin/bash -ceu \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -qAt -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT marker FROM upgrade_smoke_sentinel WHERE id = 1;"'
}
keyring_path=/var/lib/postgresql/tde-keyring/chronicle-keyring.per
docker compose stop backend db-backup postgres >/dev/null
docker compose run --rm --no-deps --entrypoint /bin/sh postgres -ceu "mv '$keyring_path' '$keyring_path.smoke-aside'" \
  || fail "could not move the keyring aside"
docker compose start postgres >/dev/null 2>&1 || true
sleep 5
keyless_output="$(postgres_query 2>&1 || true)"
keyless_output+="$(docker compose logs --tail=50 postgres 2>&1)"
! grep -qx 'before-upgrade' <<<"$(postgres_query 2>/dev/null || true)" ||
  fail "encrypted data was readable without the keyring"
grep -Eqi 'key provider|principal key' <<<"$keyless_output" ||
  fail "keyless start did not report the missing TDE key"
docker compose stop postgres >/dev/null
docker compose run --rm --no-deps --entrypoint /bin/sh postgres -ceu "mv '$keyring_path.smoke-aside' '$keyring_path'" \
  || fail "could not put the keyring back"
docker compose up -d --wait --wait-timeout 300 >/dev/null
[[ "$(postgres_query)" == before-upgrade ]] || fail "data did not recover after the keyring was restored"
verify_with_dashboard_password >/dev/null

printf 'Proving the internal password guard rate-limits repeated failures.\n'
sed -i 's/^RATE_LIMIT_GUARD_EVENTS=.*/RATE_LIMIT_GUARD_EVENTS=5/' .env
grep -q '^RATE_LIMIT_GUARD_EVENTS=5$' .env || printf 'RATE_LIMIT_GUARD_EVENTS=5\n' >>.env
docker compose up -d --wait --wait-timeout 120 web >/dev/null
guard_codes="$(for _ in 1 2 3 4 5 6 7 8; do
  printf '%s' '{"password":"wrong-password"}' | curl_internal /chronicle/v3/auth/dashboard-login \
    -H 'Content-Type: application/json' --data-binary @- -o /dev/null -w '%{http_code}\n'
done)"
grep -qx 429 <<<"$guard_codes" || fail "repeated wrong passwords were never rate-limited: $(tr '\n' ' ' <<<"$guard_codes")"
if [[ "$MONITORING" == true ]]; then
  login_query_url="$(python3 - "$BUNDLE/monitoring/grafana-alerting/rules.yml" <<'PY_LOGIN_QUERY'
import json
import sys
from urllib.parse import urlencode

with open(sys.argv[1]) as source:
    rules = json.load(source)
rule = next(rule for group in rules["groups"] for rule in group["rules"] if rule["uid"] == "failed-login-spike")
# The alert is a VictoriaMetrics query, so the smoke asks VictoriaMetrics the same question.
print("http://victoriametrics:8428/api/v1/query?" + urlencode({"query": rule["data"][0]["model"]["expr"]}))
PY_LOGIN_QUERY
)"
  login_deadline=$((SECONDS + 60))
  login_failures_visible=false
  while (( SECONDS < login_deadline )); do
    if docker compose exec -T grafana wget -T 10 -qO- "$login_query_url" >"${RUN_DIR}/login-failures.json" &&
        jq -e '(.data.result[0].value[1] // "0" | tonumber) > 0' "${RUN_DIR}/login-failures.json" >/dev/null; then
      login_failures_visible=true
      break
    fi
    sleep 2
  done
  [[ "$login_failures_visible" == true ]] || fail "the password alert query did not observe Caddy guard refusals"
fi

printf 'Qualifying real remote enrollment and persisted uploads through TLS termination.\n'
# Explicit subnets: the bundle default (172.28.0.0/16) may already belong to another stack on this host.
TOPOLOGY_SUBNET=10.253.54.0/24 bash "$ROOT_DIR/tests/deployment/selfhost-topology.sh" "$NEW_BUNDLE"
TOPOLOGY_SOURCE_PRESERVING=true TOPOLOGY_SUBNET=10.253.56.0/24 bash "$ROOT_DIR/tests/deployment/selfhost-topology.sh" "$NEW_BUNDLE"
TOPOLOGY_SUBNET=10.253.55.0/24 TOPOLOGY_FORWARD_CLIENT=false bash "$ROOT_DIR/tests/deployment/selfhost-topology.sh" "$NEW_BUNDLE"

{
  echo 'status=passed'
  echo 'source_free_archive=pass'
  echo "fresh_install=$fresh_install"
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
  echo "study_restart_persistence=$study_restart_persistence"
  echo 'clean_restore=pass'
  echo "disk_full_recovery=${disk_full_recovery}"
  echo "clean_restore_seconds=${clean_restore_seconds}"
  echo 'dashboard_headers=pass'
  echo "container_security_audit=${container_security_audit}"
  echo 'keyless_volume_fails=pass'
  echo 'internal_guard_rate_limit=pass'
  echo 'post_restore_verify=pass'
  echo "monitoring=${MONITORING}"
  [[ "$MONITORING" != true ]] || echo 'monitoring_data_path=pass'
  echo "source_revision=${REVISION}"
  printf '%s\n' "$previous_release_evidence"
  echo "release_version=${NEW_VERSION}"
  printf '%s=%s\n' "$SMOKE_ARCHIVE_HASH_FIELD" "$RELEASE_ARCHIVE_SHA256"
} >"${RUN_DIR}/result.txt"
SMOKE_PASSED=true
