#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Run from a newly extracted release bundle:
#
#   ./chronicle upgrade --from /absolute/path/to/previous/selfhost
#
# The previous stack stays live while the new bundle, images, configuration, and database
# major version are validated. The command then stops every application writer, takes the
# rollback dump from the quiesced database, and hands the same Compose project to the new
# release. This prevents writes from landing after the rollback snapshot.

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./chronicle upgrade --from /path/to/previous/selfhost

Run this command from the newly extracted release. It validates both release bundles,
merges the previous operator settings with the new release defaults and image pins, keeps
the previous backups/TLS state directory, takes and verifies a pre-upgrade SQL dump, starts
the new release, and verifies the external exposure boundary.
EOF
}

[[ "$#" -eq 2 && "$1" == --from ]] || { usage >&2; exit 2; }

for command in docker python3 gzip sha256sum awk date stat; do
  command -v "$command" >/dev/null 2>&1 || fail "required command is unavailable: $command"
done
docker compose version >/dev/null 2>&1 || fail "the Docker Compose plugin is unavailable"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
NEW_DIR="$SCRIPT_DIR"
OLD_DIR="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$2")"
cd "$NEW_DIR"

[[ "$OLD_DIR" != "$NEW_DIR" ]] || fail "--from must name a different release directory"
[[ -d "$OLD_DIR" ]] || fail "previous selfhost directory does not exist: $OLD_DIR"
[[ -f "${OLD_DIR}/.env" && ! -L "${OLD_DIR}/.env" ]] ||
  fail "previous release .env must be a regular file: ${OLD_DIR}/.env"
old_env_mode="$(stat -c '%a' "${OLD_DIR}/.env" 2>/dev/null || stat -f '%Lp' "${OLD_DIR}/.env" 2>/dev/null || true)"
[[ "$old_env_mode" == 600 ]] ||
  fail "previous release .env is mode ${old_env_mode:-unknown}; run chmod 600 ${OLD_DIR}/.env before upgrading"
[[ -f "${OLD_DIR}/../release-manifest.json" ]] ||
  fail "previous release manifest is missing: ${OLD_DIR}/../release-manifest.json"
[[ -f "${NEW_DIR}/../release-manifest.json" ]] ||
  fail "new release manifest is missing: ${NEW_DIR}/../release-manifest.json"
[[ ! -e "${NEW_DIR}/.env" ]] ||
  fail "new release already has .env; refusing to overwrite it (extract a clean bundle)"

ENV_GENERATED=false
STACK_CHANGE_STARTED=false
OLD_APPLICATION_STOP_ATTEMPTED=false
NEW_STACK_START_ATTEMPTED=false
UPGRADE_LOCK_HELD=false
UPGRADE_LOCK_DIR=""
backup_partial=""

cleanup() {
  local original_status=$?
  set +e
  if [[ -n "$backup_partial" ]]; then
    BACKUP_PARTIAL="$backup_partial" python3 - <<'PY'
from pathlib import Path
import os

Path(os.environ["BACKUP_PARTIAL"]).unlink(missing_ok=True)
PY
  fi
  if [[ "$original_status" -ne 0 && "$OLD_APPLICATION_STOP_ATTEMPTED" == true && "$NEW_STACK_START_ATTEMPTED" != true ]]; then
    printf 'Upgrade stopped before the new release was started; restarting the previous release.\n' >&2
    if compose_old up -d --wait --wait-timeout "$UPGRADE_WAIT_TIMEOUT_SECONDS" --remove-orphans; then
      OLD_APPLICATION_STOP_ATTEMPTED=false
      printf 'Previous release is healthy again.\n' >&2
    else
      printf 'WARNING: the previous release did not return healthy. Its database schema was not changed; diagnose the old stack before retrying.\n' >&2
    fi
  fi
  if [[ "$original_status" -ne 0 && "$ENV_GENERATED" == true && "$STACK_CHANGE_STARTED" != true ]]; then
    NEW_ENV="${NEW_DIR}/.env" python3 - <<'PY'
from pathlib import Path
import os

Path(os.environ["NEW_ENV"]).unlink(missing_ok=True)
PY
  fi
  if [[ "$UPGRADE_LOCK_HELD" == true && -n "$UPGRADE_LOCK_DIR" ]]; then
    /bin/rmdir "$UPGRADE_LOCK_DIR" 2>/dev/null || true
  fi
  return "$original_status"
}
trap cleanup EXIT

# The archive checksum is the publication trust root. This second check detects accidental
# edits, partial copies, or a release directory mixed with files from another version before
# any image is pulled or database command is run.
release_line="$(
  python3 - "${OLD_DIR}/../release-manifest.json" "${NEW_DIR}/../release-manifest.json" <<'PY'
from pathlib import Path, PurePosixPath
import hashlib
import json
import re
import sys

version_re = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
revision_re = re.compile(r"^[0-9a-f]{40}$")
digest_re = re.compile(r"^[0-9a-f]{64}$")


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_version(version, manifest_path):
    match = version_re.fullmatch(version)
    if not match:
        raise SystemExit(f"invalid release version in {manifest_path}: {version!r}")
    prerelease = match.group(4)
    if prerelease is None:
        pre_key = (1,)
    else:
        identifiers = []
        for part in prerelease.split("."):
            if part.isdigit():
                if len(part) > 1 and part.startswith("0"):
                    raise SystemExit(
                        f"invalid numeric prerelease identifier in {manifest_path}: {part!r}"
                    )
                identifiers.append((0, int(part)))
            else:
                identifiers.append((1, part))
        pre_key = (0, *identifiers)
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)), pre_key)


def read_env(path):
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
        if match:
            value = match.group(2).strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            values[match.group(1)] = value
    return values


def read_manifest(path, require_upgrade_script):
    manifest_path = Path(path)
    bundle = manifest_path.parent
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise SystemExit(f"release manifest is missing or unsafe: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 1:
        raise SystemExit(f"unsupported release manifest schema in {manifest_path}")
    version = manifest.get("release_version", "")
    version_key = parse_version(version, manifest_path)
    revision = manifest.get("source_revision", "")
    if not revision_re.fullmatch(revision):
        raise SystemExit(f"invalid source revision in {manifest_path}")
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        raise SystemExit(f"release manifest has no file inventory: {manifest_path}")
    required = {
        "selfhost/.env.example",
        "selfhost/chronicle",
        "selfhost/docker-compose.yml",
        "selfhost/restore.sh",
    }
    if require_upgrade_script:
        required.update(
            {
                "selfhost/upgrade.sh",
                "selfhost/rotate-secret.sh",
                "selfhost/docs/DEPLOYMENT-COMPATIBILITY.md",
                "selfhost/docs/SECRET-ROTATION.md",
                "selfhost/docs/UNINSTALL-DATA-DELETION.md",
            }
        )
    missing = sorted(required - set(files))
    if missing:
        raise SystemExit(
            f"release manifest omits required files in {manifest_path}: {', '.join(missing)}"
        )
    for relative_text, expected in sorted(files.items()):
        if not isinstance(relative_text, str) or not isinstance(expected, str):
            raise SystemExit(f"malformed file inventory entry in {manifest_path}")
        relative = PurePosixPath(relative_text)
        if relative.is_absolute() or ".." in relative.parts or relative.as_posix() != relative_text:
            raise SystemExit(f"unsafe file path in {manifest_path}: {relative_text!r}")
        if not digest_re.fullmatch(expected):
            raise SystemExit(f"invalid checksum for {relative_text} in {manifest_path}")
        candidate = bundle.joinpath(*relative.parts)
        if not candidate.is_file() or candidate.is_symlink():
            raise SystemExit(f"release file is missing or unsafe: {candidate}")
        actual = file_sha256(candidate)
        if actual != expected:
            raise SystemExit(
                f"release file checksum mismatch: {candidate} (expected {expected}, got {actual})"
            )

    # The new release must still be the clean extraction checked by the publisher. Without
    # an exact inventory check, a stale or injected unlisted file can participate in Compose
    # even though every path the manifest happens to mention has a valid checksum. The old
    # release legitimately contains runtime .env/backups/TLS files, so it is checked by hash
    # for its inventory but cannot use this clean-extraction assertion.
    if require_upgrade_script:
        actual_files = set()
        for entry in bundle.rglob("*"):
            if entry.is_symlink():
                raise SystemExit(f"unsafe symlink in new release: {entry}")
            if entry.is_file():
                relative = entry.relative_to(bundle).as_posix()
                if relative != "release-manifest.json":
                    actual_files.add(relative)
            elif not entry.is_dir():
                raise SystemExit(f"unsupported file type in new release: {entry}")
        inventory_files = set(files)
        if actual_files != inventory_files:
            unlisted = sorted(actual_files - inventory_files)
            absent = sorted(inventory_files - actual_files)
            details = []
            if unlisted:
                details.append("unlisted files: " + ", ".join(unlisted[:10]))
            if absent:
                details.append("missing files: " + ", ".join(absent[:10]))
            raise SystemExit(
                f"new release file inventory is not exact in {manifest_path}: "
                + "; ".join(details)
            )

    env = read_env(bundle / "selfhost" / ".env.example")
    if env.get("RELEASE_VERSION") != version:
        raise SystemExit(
            f"manifest version does not match selfhost/.env.example in {manifest_path}"
        )
    images = manifest.get("images")
    expected_images = {
        "backend": env.get("BACKEND_IMAGE"),
        "frontend": env.get("SELFHOST_FRONTEND_IMAGE"),
        "caddy": env.get("CADDY_IMAGE"),
    }
    if images != expected_images:
        raise SystemExit(
            f"manifest image inventory does not match selfhost/.env.example in {manifest_path}"
        )
    return manifest, version_key


old, old_key = read_manifest(sys.argv[1], False)
new, new_key = read_manifest(sys.argv[2], True)
if new_key <= old_key:
    raise SystemExit(
        f"new release {new['release_version']} must be newer than previous release "
        f"{old['release_version']}"
    )
print(
    "\t".join(
        [
            old["release_version"],
            new["release_version"],
            old["source_revision"],
            new["source_revision"],
        ]
    )
)
PY
)" || fail "release bundle validation failed; the running release was not changed"
IFS=$'\t' read -r OLD_VERSION NEW_VERSION OLD_REVISION NEW_REVISION <<<"$release_line"
[[ -n "$OLD_VERSION" && -n "$NEW_VERSION" && -n "$OLD_REVISION" && -n "$NEW_REVISION" ]] ||
  fail "could not read validated release metadata"

# Resolve only the declared supported Compose shape. Reusing an absolute COMPOSE_FILE from
# the old directory would silently run old definitions with new image pins; activating the
# restore profile during `up` would be destructive. Normalize known files to this release
# and reject every other Compose control variable.
configuration_line="$(
  python3 - "${OLD_DIR}/.env" "$OLD_DIR" <<'PY'
from pathlib import Path, PurePosixPath
import os
import re
import sys

values = {}
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    match = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
    if not match:
        continue
    value = match.group(2).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        value = value[1:-1]
    values[match.group(1)] = value

for key in values:
    if key.startswith("COMPOSE_") and key not in {"COMPOSE_FILE", "COMPOSE_PROJECT_NAME"}:
        raise SystemExit(
            f"unsupported Compose control setting in previous .env: {key}; remove it and retry"
        )

old_dir = Path(sys.argv[2]).resolve()
state_text = values.get("CHRONICLE_STATE_DIR", ".") or "."
state_path = Path(state_text)
if not state_path.is_absolute():
    state_path = old_dir / state_path
state = str(state_path.resolve())
if any(character in state for character in ("\n", "\r", "\t", "'")):
    raise SystemExit("CHRONICLE_STATE_DIR contains an unsupported control character or quote")

project = values.get("COMPOSE_PROJECT_NAME", "chronicle-selfhost")
if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", project):
    raise SystemExit(f"invalid COMPOSE_PROJECT_NAME in previous .env: {project!r}")

allowed = {
    "docker-compose.yml",
    "overlays/mode-behind-proxy-internal.yml",
    "overlays/mode-local-https.yml",
    "overlays/mode-own-tls-internal.yml",
    "overlays/backups.yml",
    "overlays/monitoring.yml",
}
raw_compose = values.get(
    "COMPOSE_FILE",
    "docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/backups.yml",
)
normalized = []
for token in raw_compose.split(":"):
    token = token.strip()
    if not token:
        raise SystemExit("previous COMPOSE_FILE contains an empty path")
    candidate = Path(token)
    if candidate.is_absolute():
        try:
            relative = candidate.resolve().relative_to(old_dir)
        except ValueError:
            raise SystemExit(
                f"previous COMPOSE_FILE references a file outside its release: {token}"
            )
        name = PurePosixPath(relative.as_posix()).as_posix()
    else:
        pure = PurePosixPath(token)
        if pure.is_absolute() or ".." in pure.parts:
            raise SystemExit(f"unsafe previous COMPOSE_FILE path: {token}")
        name = pure.as_posix()
    if name in {
        "overlays/mode-behind-proxy-public.yml",
        "overlays/mode-own-tls-public.yml",
    }:
        raise SystemExit(
            "the previous release uses a retired public-dashboard mode; convert and verify "
            "that release with the matching mode-*-internal overlay before upgrading"
        )
    if name not in allowed:
        raise SystemExit(f"unsupported previous Compose file: {name}")
    if name in normalized:
        raise SystemExit(f"duplicate previous Compose file: {name}")
    normalized.append(name)

if normalized.count("docker-compose.yml") != 1:
    raise SystemExit("previous COMPOSE_FILE must contain docker-compose.yml exactly once")
modes = [name for name in normalized if name.startswith("overlays/mode-")]
if len(modes) != 1:
    raise SystemExit("previous COMPOSE_FILE must contain exactly one supported mode overlay")

compose_file = ":".join(normalized)
print("\t".join([state, project, compose_file]))
PY
)" || fail "previous deployment configuration is not safe to upgrade"
IFS=$'\t' read -r STATE_ROOT PROJECT NORMALIZED_COMPOSE_FILE <<<"$configuration_line"
[[ -n "$STATE_ROOT" && -n "$PROJECT" && -n "$NORMALIZED_COMPOSE_FILE" ]] ||
  fail "could not read previous state configuration"
BACKUPS_DIR="${STATE_ROOT}/backups"
TLS_DIR="${STATE_ROOT}/tls"

[[ -d "$BACKUPS_DIR" ]] || fail "previous backups directory is missing: $BACKUPS_DIR"
[[ -d "$TLS_DIR" ]] || fail "previous TLS directory is missing: $TLS_DIR"

# Compose gives inherited shell variables precedence over an explicit env file. An operator
# who once exported BACKEND_IMAGE, COMPOSE_FILE, COMPOSE_PROFILES, or any other interpolation
# input could otherwise make this command validate one release and start a different shape or
# image. Use only the validated file list and the selected release's env file for deployment
# inputs while retaining Docker connectivity variables such as DOCKER_HOST/DOCKER_CONTEXT.
compose_for_release() {
  local release_dir="$1" env_file="$2"
  shift 2
  local -a compose_options=(--env-file "$env_file" --project-name "$PROJECT")
  local -a compose_paths=()
  local compose_name compose_path line remainder variable
  IFS=: read -r -a compose_paths <<<"$NORMALIZED_COMPOSE_FILE"
  for compose_name in "${compose_paths[@]}"; do
    compose_path="${release_dir}/${compose_name}"
    [[ -f "$compose_path" && ! -L "$compose_path" ]] ||
      fail "validated Compose file is missing or unsafe: $compose_path"
    compose_options+=(-f "$compose_path")
  done

  (
    # Remove every assignment supplied by this release before Compose reads --env-file, and
    # remove every variable referenced by the selected YAML even when it is only documented
    # as a commented optional setting. This keeps the env file authoritative without putting
    # its secrets into the environment of unrelated child processes.
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]*#?[[:space:]]*([A-Z][A-Z0-9_]*)= ]]; then
        variable="${BASH_REMATCH[1]}"
        unset "$variable" 2>/dev/null ||
          fail "could not isolate inherited deployment setting: $variable"
      fi
    done <"$env_file"
    for compose_path in "${compose_options[@]}"; do
      [[ "$compose_path" == *.yml || "$compose_path" == *.yaml ]] || continue
      while IFS= read -r line || [[ -n "$line" ]]; do
        remainder="$line"
        while [[ "$remainder" =~ \$\{([A-Z][A-Z0-9_]*) ]]; do
          variable="${BASH_REMATCH[1]}"
          unset "$variable" 2>/dev/null ||
            fail "could not isolate inherited deployment setting: $variable"
          remainder="${remainder:1}"
        done
      done <"$compose_path"
    done
    for variable in "${!COMPOSE_@}"; do
      unset "$variable" 2>/dev/null ||
        fail "could not isolate inherited Compose setting: $variable"
    done
    docker compose "${compose_options[@]}" "$@"
  )
}

compose_old() { compose_for_release "$OLD_DIR" "${OLD_DIR}/.env" "$@"; }
compose_new() { compose_for_release "$NEW_DIR" "${NEW_DIR}/.env" "$@"; }

UPGRADE_LOCK_DIR="${STATE_ROOT}/.chronicle-upgrade.lock"
ROTATION_LOCK_DIR="${STATE_ROOT}/.chronicle-secret-rotation"
RESTORE_LOCK_DIR="${STATE_ROOT}/.chronicle-restore.lock"
[[ ! -e "$ROTATION_LOCK_DIR" && ! -L "$ROTATION_LOCK_DIR" ]] ||
  fail "a secret rotation is active or incomplete ($ROTATION_LOCK_DIR); finish its documented recovery before upgrading"
[[ ! -e "$RESTORE_LOCK_DIR" && ! -L "$RESTORE_LOCK_DIR" ]] ||
  fail "a restore is active or incomplete ($RESTORE_LOCK_DIR); finish its documented recovery before upgrading"
if ! /bin/mkdir "$UPGRADE_LOCK_DIR" 2>/dev/null; then
  fail "another upgrade may be active (lock exists: $UPGRADE_LOCK_DIR). If no upgrade process is running, remove only that empty directory and retry."
fi
UPGRADE_LOCK_HELD=true
# The prechecks and mkdir are separate operations. Recheck after owning our lock so two
# commands that started together cannot both pass their first check and proceed.
[[ ! -e "$ROTATION_LOCK_DIR" && ! -L "$ROTATION_LOCK_DIR" ]] ||
  fail "a secret rotation started while the upgrade lock was being acquired; upgrade did not start"
[[ ! -e "$RESTORE_LOCK_DIR" && ! -L "$RESTORE_LOCK_DIR" ]] ||
  fail "a restore started while the upgrade lock was being acquired; upgrade did not start"

old_postgres="$(compose_old ps -q postgres)"
[[ -n "$old_postgres" ]] || fail "previous PostgreSQL container is not running"
old_postgres_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$old_postgres")"
[[ "$old_postgres_health" == healthy ]] ||
  fail "previous PostgreSQL is not healthy (state: $old_postgres_health)"
old_postgres_version_num="$(
  docker exec "$old_postgres" /bin/bash -ceu \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "${POSTGRES_USER:-chronicle}" -d "${POSTGRES_DB:-chronicle}" -tAqc "SHOW server_version_num"'
)" || fail "could not read the running PostgreSQL version"
[[ "$old_postgres_version_num" =~ ^[0-9]+$ ]] ||
  fail "running PostgreSQL returned an invalid server_version_num"
OLD_POSTGRES_MAJOR=$((old_postgres_version_num / 10000))

# V95 intentionally refuses encrypted collection until participant exports can decrypt it.
# Detect that unsupported state while the previous release is still fully available, before
# rendering the new environment, stopping writers, or starting a migration. A failed query is
# indeterminate and must stop the upgrade rather than being treated as an empty result.
study_encryption_status="$(
  docker exec "$old_postgres" /bin/bash -ceu \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "${POSTGRES_USER:-chronicle}" -d "${POSTGRES_DB:-chronicle}" -tAqc "SELECT CASE WHEN EXISTS (SELECT 1 FROM studies WHERE settings #> '\''{Encryption,enabled}'\'' = '\''true'\''::JSONB) THEN '\''blocked'\'' ELSE '\''clear'\'' END"'
)" || fail "could not evaluate the study-encryption upgrade precondition; the previous release was not changed"
[[ "$study_encryption_status" == clear || "$study_encryption_status" == blocked ]] ||
  fail "study-encryption preflight returned an invalid result; the previous release was not changed"

encrypted_payloads_table_status="$(
  docker exec "$old_postgres" /bin/bash -ceu \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "${POSTGRES_USER:-chronicle}" -d "${POSTGRES_DB:-chronicle}" -tAqc "SELECT CASE WHEN to_regclass('\''public.encrypted_payloads'\'') IS NULL THEN '\''absent'\'' ELSE '\''present'\'' END"'
)" || fail "could not evaluate the encrypted-payload upgrade precondition; the previous release was not changed"
[[ "$encrypted_payloads_table_status" == absent || "$encrypted_payloads_table_status" == present ]] ||
  fail "encrypted-payload preflight returned an invalid table result; the previous release was not changed"

encrypted_payloads_status=clear
if [[ "$encrypted_payloads_table_status" == present ]]; then
  encrypted_payloads_status="$(
    docker exec "$old_postgres" /bin/bash -ceu \
      'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "${POSTGRES_USER:-chronicle}" -d "${POSTGRES_DB:-chronicle}" -tAqc "SELECT CASE WHEN EXISTS (SELECT 1 FROM encrypted_payloads) THEN '\''blocked'\'' ELSE '\''clear'\'' END"'
  )" || fail "could not inspect historical encrypted payloads; the previous release was not changed"
  [[ "$encrypted_payloads_status" == clear || "$encrypted_payloads_status" == blocked ]] ||
    fail "encrypted-payload preflight returned an invalid row result; the previous release was not changed"
fi

if [[ "$study_encryption_status" == blocked || "$encrypted_payloads_status" == blocked ]]; then
  fail "this release cannot safely export study-encrypted collection data. Keep the previous release running; do not delete ciphertext to force the upgrade. Complete an approved decrypt-and-export migration plan, then retry. See docs/UPGRADE-ROLLBACK.md."
fi

printf 'Preparing Chronicle %s -> %s.\n' "$OLD_VERSION" "$NEW_VERSION"
printf '  previous release: %s\n' "$OLD_DIR"
printf '  preserved state:  %s\n' "$STATE_ROOT"

# Build the new .env from the new release template so newly introduced settings receive
# documented defaults. Preserve previous operator values, but never preserve release-managed
# image/version pins or Compose paths. The new release files and normalized supported overlay
# list are the only authorities for those values.
OLD_ENV="${OLD_DIR}/.env" \
NEW_TEMPLATE="${NEW_DIR}/.env.example" \
NEW_ENV="${NEW_DIR}/.env" \
STATE_ROOT="$STATE_ROOT" \
NORMALIZED_COMPOSE_FILE="$NORMALIZED_COMPOSE_FILE" \
python3 - <<'PY'
from pathlib import Path
import os
import re

old_path = Path(os.environ["OLD_ENV"])
template_path = Path(os.environ["NEW_TEMPLATE"])
destination = Path(os.environ["NEW_ENV"])
managed = {
    "RELEASE_VERSION",
    "BACKEND_IMAGE",
    "SELFHOST_FRONTEND_IMAGE",
    "CADDY_IMAGE",
    "POSTGRES_IMAGE",
    "CHRONICLE_STATE_DIR",
    "COMPOSE_FILE",
}
assignment = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")
template_assignment = re.compile(r"^(?P<key>[A-Z][A-Z0-9_]*)=(?P<value>.*)$")
old_values = {}
for line in old_path.read_text(encoding="utf-8").splitlines():
    match = assignment.match(line)
    if match:
        old_values[match.group(1)] = match.group(2)

state_root = os.environ["STATE_ROOT"]
old_values["CHRONICLE_STATE_DIR"] = f"'{state_root}'"
old_values["COMPOSE_FILE"] = os.environ["NORMALIZED_COMPOSE_FILE"]
seen = set()
rendered = []
for line in template_path.read_text(encoding="utf-8").splitlines():
    match = template_assignment.match(line)
    if not match:
        rendered.append(line)
        continue
    key = match.group("key")
    if key in seen:
        raise SystemExit(f"new .env.example contains duplicate assignment: {key}")
    seen.add(key)
    if key in {"CHRONICLE_STATE_DIR", "COMPOSE_FILE"}:
        rendered.append(f"{key}={old_values[key]}")
    elif key in old_values and key not in managed and not key.endswith("_IMAGE"):
        rendered.append(f"{key}={old_values[key]}")
    else:
        rendered.append(line)

unknown = sorted(
    key
    for key in set(old_values) - seen - managed
    if not key.startswith("COMPOSE_") and not key.endswith("_IMAGE")
)
if unknown:
    rendered.extend(["", "# Previous operator settings not present in this release template."])
    rendered.extend(f"{key}={old_values[key]}" for key in unknown)

content = "\n".join(rendered) + "\n"
if "__CHRONICLE_" in content:
    raise SystemExit("new .env.example still contains unresolved release image placeholders")
temporary = destination.with_name(f".{destination.name}.upgrade-{os.getpid()}")
try:
    with temporary.open("x", encoding="utf-8") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    temporary.chmod(0o600)
    os.replace(temporary, destination)
    directory_fd = os.open(destination.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    temporary.unlink(missing_ok=True)
PY
ENV_GENERATED=true

printf 'Validating new release configuration and pulling immutable images.\n'
compose_new config --quiet
compose_new pull --policy missing
compose_new run --rm --no-deps config-guard

new_postgres_image="$(
  compose_new config --format json |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["postgres"]["image"])'
)" || fail "could not resolve the new PostgreSQL image"
new_postgres_version="$(
  docker run --rm --network none --read-only --cap-drop ALL --entrypoint postgres \
    "$new_postgres_image" --version
)" || fail "could not inspect the PostgreSQL version in $new_postgres_image"
new_postgres_major="$(
  NEW_POSTGRES_VERSION="$new_postgres_version" python3 - <<'PY'
import os
import re

match = re.search(r"PostgreSQL\)?\s+([0-9]+)", os.environ["NEW_POSTGRES_VERSION"])
if not match:
    raise SystemExit("unrecognized postgres --version output")
print(match.group(1))
PY
)" || fail "could not parse the PostgreSQL version in $new_postgres_image"
[[ "$new_postgres_major" == "$OLD_POSTGRES_MAJOR" ]] ||
  fail "automatic upgrade refuses PostgreSQL major ${OLD_POSTGRES_MAJOR} -> ${new_postgres_major} against the same data volume. Follow docs/POSTGRES-18-UPGRADE.md for a dump/restore major upgrade."
printf '  PostgreSQL major %s is compatible with the running data volume.\n' "$OLD_POSTGRES_MAJOR"

: "${UPGRADE_WAIT_TIMEOUT_SECONDS:=300}"
[[ "$UPGRADE_WAIT_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  fail "UPGRADE_WAIT_TIMEOUT_SECONDS must be a positive integer"
(( UPGRADE_WAIT_TIMEOUT_SECONDS <= 3600 )) ||
  fail "UPGRADE_WAIT_TIMEOUT_SECONDS must not exceed 3600"

/bin/chmod 0700 "$BACKUPS_DIR"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_id="${timestamp}-$$"
backup_path="${BACKUPS_DIR}/pre-upgrade-${OLD_VERSION}-to-${NEW_VERSION}-${run_id}.sql.gz"
backup_partial="${backup_path}.partial"
[[ ! -e "$backup_path" && ! -L "$backup_path" && ! -e "$backup_partial" && ! -L "$backup_partial" ]] ||
  fail "pre-upgrade backup destination already exists: $backup_path"

old_service_list="$(compose_old config --services)" ||
  fail "previous Docker Compose configuration is invalid"
for required_service in postgres backend web db-init; do
  grep -Fxq "$required_service" <<<"$old_service_list" ||
    fail "previous Docker Compose configuration is missing required service: $required_service"
done
old_application_services=(backend web db-init)
if grep -Fxq db-backup <<<"$old_service_list"; then
  old_application_services+=(db-backup)
fi

# A live pg_dump is transaction-consistent, but writes committed after its snapshot and
# before the container handoff would disappear on rollback. Quiesce every supported database
# writer first, verify it is stopped, and only then create the rollback point. A failure
# before the new stack starts is handled by the EXIT trap, which restarts this old release.
printf 'Quiescing the previous release before its rollback backup: %s\n' "${old_application_services[*]}"
OLD_APPLICATION_STOP_ATTEMPTED=true
compose_old stop "${old_application_services[@]}" ||
  fail "could not stop every previous application service; the old release will be restarted"
old_running_services="$(compose_old ps --status running --services)" ||
  fail "could not verify that previous application services stopped"
for required_service in "${old_application_services[@]}"; do
  if grep -Fxq "$required_service" <<<"$old_running_services"; then
    fail "previous Compose service '$required_service' is still running; backup was not started"
  fi
done
grep -Fxq postgres <<<"$old_running_services" ||
  fail "previous PostgreSQL stopped while application services were quiesced"

printf 'Taking a consistent pre-upgrade SQL dump with application writers stopped.\n'
if ! compose_old exec -T postgres /bin/bash -ceu \
    'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h 127.0.0.1 -U "${POSTGRES_USER:-chronicle}" -d "${POSTGRES_DB:-chronicle}" --no-owner --no-privileges' \
    | gzip -c >"$backup_partial"; then
  fail "pre-upgrade database dump failed; the previous release will be restarted"
fi
[[ -s "$backup_partial" ]] || fail "pre-upgrade database dump is empty"
gzip -t "$backup_partial" || fail "pre-upgrade database dump failed gzip verification"
/bin/chmod 0600 "$backup_partial"
BACKUP_PARTIAL="$backup_partial" BACKUP_FINAL="$backup_path" python3 - <<'PY'
from pathlib import Path
import os

source = Path(os.environ["BACKUP_PARTIAL"])
destination = Path(os.environ["BACKUP_FINAL"])
with source.open("rb") as handle:
    os.fsync(handle.fileno())
os.replace(source, destination)
directory_fd = os.open(destination.parent, os.O_RDONLY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
backup_partial=""
backup_sha256="$(sha256sum "$backup_path" | awk '{print $1}')"
printf '  verified pre-upgrade backup: %s\n' "$backup_path"

RECEIPT_DIR="${STATE_ROOT}/upgrade-receipts"
/bin/mkdir -p "$RECEIPT_DIR"
/bin/chmod 0700 "$RECEIPT_DIR"
receipt_path="${RECEIPT_DIR}/${run_id}-${OLD_VERSION}-to-${NEW_VERSION}.json"

write_receipt() {
  local result="$1"
  RECEIPT_PATH="$receipt_path" \
  RESULT="$result" \
  OLD_VERSION="$OLD_VERSION" NEW_VERSION="$NEW_VERSION" \
  OLD_REVISION="$OLD_REVISION" NEW_REVISION="$NEW_REVISION" \
  BACKUP_PATH="$backup_path" BACKUP_SHA256="$backup_sha256" \
  PROJECT="$PROJECT" TIMESTAMP="$timestamp" \
  python3 - <<'PY'
from pathlib import Path
import json
import os

destination = Path(os.environ["RECEIPT_PATH"])
payload = {
    "schema_version": 1,
    "status": os.environ["RESULT"],
    "timestamp_utc": os.environ["TIMESTAMP"],
    "compose_project": os.environ["PROJECT"],
    "from": {
        "version": os.environ["OLD_VERSION"],
        "source_revision": os.environ["OLD_REVISION"],
    },
    "to": {
        "version": os.environ["NEW_VERSION"],
        "source_revision": os.environ["NEW_REVISION"],
    },
    "pre_upgrade_backup": {
        "path": os.environ["BACKUP_PATH"],
        "sha256": os.environ["BACKUP_SHA256"],
    },
}
temporary = destination.with_name(f".{destination.name}.{os.getpid()}")
try:
    with temporary.open("x", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    temporary.chmod(0o600)
    os.replace(temporary, destination)
    directory_fd = os.open(destination.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    temporary.unlink(missing_ok=True)
PY
}

printf 'Starting Chronicle %s (bounded wait: %ss).\n' "$NEW_VERSION" "$UPGRADE_WAIT_TIMEOUT_SECONDS"
startup_services=()
has_ca_export=false
if ! configured_services="$(compose_new config --services)"; then
  write_receipt failed-service-discovery
  printf 'Upgrade could not resolve the new release service graph. The verified backup remains at:\n' >&2
  printf '  %s\n' "$backup_path" >&2
  exit 1
fi
while IFS= read -r service; do
  [[ -n "$service" ]] || continue
  if [[ "$service" == ca-export ]]; then
    # ca-export intentionally exits after writing/printing the local CA. Compose --wait treats
    # that successful one-shot as a failed long-running service, so run it separately after the
    # actual stack is healthy.
    has_ca_export=true
  else
    startup_services+=("$service")
  fi
done <<<"$configured_services"
[[ "${#startup_services[@]}" -gt 0 ]] || fail "new release has no long-running services"
NEW_STACK_START_ATTEMPTED=true
STACK_CHANGE_STARTED=true
if ! compose_new up -d --wait --wait-timeout "$UPGRADE_WAIT_TIMEOUT_SECONDS" \
    --remove-orphans "${startup_services[@]}"; then
  write_receipt failed
  printf '\nUpgrade startup failed. The verified backup is unchanged at:\n  %s\n' "$backup_path" >&2
  printf 'Do not start the previous backend against a possibly migrated schema. Diagnose and\n' >&2
  printf 'continue forward from this bundle, or follow docs/UPGRADE-ROLLBACK.md to restore the\n' >&2
  printf 'pre-upgrade dump before starting the previous release.\n' >&2
  exit 1
fi

if [[ "$has_ca_export" == true ]] && ! compose_new run --rm --no-deps ca-export; then
  write_receipt failed-ca-export
  printf 'Upgrade services are healthy, but the local CA export failed. Continue forward from\n' >&2
  printf 'this bundle after correcting ca-export; the verified backup remains at %s.\n' "$backup_path" >&2
  exit 1
fi

if ! ./chronicle verify; then
  write_receipt failed-verification
  printf 'Upgrade containers started, but external verification failed. Continue forward from\n' >&2
  printf 'this bundle; the verified pre-upgrade dump remains at %s.\n' "$backup_path" >&2
  exit 1
fi

write_receipt succeeded
printf '\nUpgrade complete: Chronicle %s is healthy and verified.\n' "$NEW_VERSION"
printf 'Receipt: %s\n' "$receipt_path"
