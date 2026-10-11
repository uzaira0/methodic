"""Release inventory and deployment settings shared by upgrade and adopt."""

from pathlib import Path, PurePosixPath
import gzip
import fcntl
import ipaddress
import json
import os
import re
import shutil
import shlex
import subprocess

from .reconcile import RECOVERY_PHASE, RECOVERY_FILE

from .common import compose_gateway, loopback_networks, run
from .dump import file_sha256, validate_dump
from .receipts import write_text

assignment = re.compile(r"^(?:export\s+)?([A-Z][A-Z0-9_]*)=(.*)$")
environment_value = re.compile(r'''(?:'[^']*'|"[^"$`\\]*"|[A-Za-z0-9_@%+=:,./-]*)(?:\s+\#.*)?''')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_env(path):
    values = {}
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = assignment.fullmatch(line)
        require(match and match[1] not in values, f"invalid or duplicate environment assignment on line {number}")
        raw = match[2]
        require(environment_value.fullmatch(raw),
                f"unsupported environment value on line {number}; use a literal quoted value, not shell syntax")
        value({match[1]: raw}, match[1])
        values[match[1]] = raw
    return values


def value(values, key, default=""):
    if key not in values:
        return default
    if values[key].lstrip().startswith("#"):
        return ""
    tokens = shlex.split(values.get(key, default), comments=True)
    require(len(tokens) <= 1, f"invalid environment value for {key}")
    return tokens[0] if tokens else ""


def free_disk_floor(settings):
    # Same precedence as need_env: .env, then the inherited environment, then 5 GiB.
    return value(settings, "MIN_FREE_DISK_GIB", os.environ.get("MIN_FREE_DISK_GIB", "5"))


def quote_env(text):
    require(not any(character in text for character in "\r\n"), "environment value cannot contain a line break")
    if "'" not in text:
        return shlex.quote(text) if text else ""
    require(not any(character in text for character in '"$`\\'), "environment value cannot combine apostrophes with shell escapes or expansion")
    return '"' + text + '"'


def compose_names(values, source):
    values = {key: value(values, key) for key in values}
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
            raise ValueError("previous COMPOSE_FILE contains an empty path")
        candidate = Path(token)
        if candidate.is_absolute():
            try:
                relative = candidate.resolve().relative_to(source)
            except ValueError:
                raise ValueError(
                    f"previous COMPOSE_FILE references a file outside its release: {token}"
                )
            name = PurePosixPath(relative.as_posix()).as_posix()
        else:
            pure = PurePosixPath(token)
            if pure.is_absolute() or ".." in pure.parts:
                raise ValueError(f"unsafe previous COMPOSE_FILE path: {token}")
            name = pure.as_posix()
        if name in {
            "overlays/mode-behind-proxy-public.yml",
            "overlays/mode-own-tls-public.yml",
        }:
            raise ValueError(
                "the previous release uses a retired public-dashboard mode; convert and verify "
                "that release with the matching mode-*-internal overlay before upgrading"
            )
        if name not in allowed:
            raise ValueError(f"unsupported previous Compose file: {name}")
        if name in normalized:
            raise ValueError(f"duplicate previous Compose file: {name}")
        normalized.append(name)

    if normalized.count("docker-compose.yml") != 1:
        raise ValueError("previous COMPOSE_FILE must contain docker-compose.yml exactly once")
    modes = [name for name in normalized if name.startswith("overlays/mode-")]
    if len(modes) != 1:
        raise ValueError("previous COMPOSE_FILE must contain exactly one supported mode overlay")
    return normalized


version_re = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
revision_re = re.compile(r"^[0-9a-f]{40}$")
digest_re = re.compile(r"^[0-9a-f]{64}$")
RELEASE_KEEP_COUNT = 3
RELEASE_SIGNER = "chronicle-release"
UPDATE_AVAILABLE_EXIT = 3
OWNER_FILE = ".chronicle-owner"


def compose_projects():
    rows = json.loads(run(["docker", "compose", "ls", "--all", "--format", "json"],
                          capture=True, check=True).stdout)
    require(isinstance(rows, list), "invalid Compose project inventory")
    return rows


def foreign_project(directory, project, adopt_source=None):
    owners = {Path(directory).resolve()}
    if adopt_source:
        owners.add(Path(adopt_source).resolve())
    for row in compose_projects():
        if row.get("Name") != project:
            continue
        configs = [path for path in (row.get("ConfigFiles") or "").split(",") if path]
        if configs and not any(Path(path).resolve().parent in owners for path in configs):
            return ",".join(configs)
    return ""


def set_current_owner(directory, state):
    marker = Path(state) / OWNER_FILE
    require(not marker.is_symlink(), "unsafe release ownership marker")
    write_text(marker, str(Path(directory).resolve()) + "\n")
    # Ownership is not secret; predecessors scan the state directory for unreadable files.
    marker.chmod(0o644)


def require_current_owner(directory, state, project):
    directory, state = Path(directory).resolve(), Path(state).resolve()
    recovery = state / ".chronicle-upgrade.lock" / RECOVERY_FILE
    if recovery.is_file() and json.loads(recovery.read_text()).get("owner") == str(directory):
        return
    marker = state / OWNER_FILE
    require(not marker.is_symlink(), "unsafe release ownership marker")
    if marker.exists():
        owner = marker.read_text().strip()
        require(owner and Path(owner).is_absolute() and Path(owner).resolve() == directory,
                f"this release was superseded; use the active selfhost directory: {owner or marker}")
    require(not foreign_project(directory, project),
            "this release does not own the live Compose project; use the active selfhost directory")
    if not marker.exists():
        script = state / "reconcile.sh"
        if script.exists():
            owner = next((shlex.split(line)[1] for line in script.read_text().splitlines()
                          if line.startswith("cd ")), None)
            require(owner is not None and Path(owner).resolve() == directory,
                    f"this release was superseded; use the active selfhost directory: {owner or script}")
        set_current_owner(directory, state)


def cleanup_releases(parent, state, apply=False, rollback_target=None):
    parent, state, active = Path(parent).resolve(), Path(state).resolve(), Path.cwd().resolve().parent
    protected = {active}
    if rollback_target is not None:
        protected.add(Path(rollback_target).resolve())
    marker = state / ".chronicle-upgrade.lock" / RECOVERY_FILE
    if marker.exists():
        protected.add(Path(json.loads(marker.read_text())["owner"]).resolve().parent)
    bundles = []
    for path in parent.glob("chronicle-selfhost-*"):
        manifest = path / "release-manifest.json"
        if path.is_symlink() or not manifest.is_file():
            continue
        data = json.loads(manifest.read_text())
        version = data["release_version"]
        require(path.name == "chronicle-selfhost-" + version, "unexpected release directory name")
        require(all(isinstance(pin, str) and "@sha256:" in pin
                    and digest_re.fullmatch(pin.rsplit("@sha256:", 1)[1])
                    for pin in data.get("images", {}).values()), "invalid cleanup image pin")
        bundles.append((parse_version(version, manifest), path, data))
        if path == state or path in state.parents:
            protected.add(path)
    live_directories = {Path(config).resolve().parent for row in compose_projects()
                        for config in (row.get("ConfigFiles") or "").split(",") if config}
    for _, path, _ in bundles:
        host = path / "selfhost"
        if (os.path.lexists(host / ".env") or any(os.path.lexists(host / name) and
                (not (host / name).is_dir() or any((host / name).iterdir()))
                for name in ("backups", "tls", "operator-receipts", "upgrade-receipts"))
                or any(directory == path or path in directory.parents for directory in live_directories)):
            protected.add(path)
            print(f"Keeping {path}: deployment configuration, private state or Compose ownership")
    bundles.sort(key=lambda row: row[0], reverse=True)
    protected.update(path for _, path, _ in bundles[:RELEASE_KEEP_COUNT])
    image_owners = protected if rollback_target is None else {active, Path(rollback_target).resolve()}
    retained_images = {pin for _, path, data in bundles if path in image_owners for pin in data.get("images", {}).values()}
    for owner in image_owners:
        env = owner / "selfhost" / ".env"
        if env.is_file() and not env.is_symlink():
            settings = read_env(env)
            retained_images.update(value(settings, key) for key in settings if key.endswith("_IMAGE"))
    for _, path, data in bundles:
        if path not in protected:
            print(f"{'Removing' if apply else 'Would remove'} {path} and its archive/checksum/signature")
        if apply and path not in protected:
            shutil.rmtree(path)
            for suffix in (".tar.gz", ".tar.gz.sha256", ".tar.gz.sha256.sig"):
                path.with_name(path.name + suffix).unlink(missing_ok=True)
    obsolete_images = {pin for _, _, data in bundles for pin in data.get("images", {}).values()} - retained_images
    for pin in sorted(obsolete_images):
        print(f"{'Removing unused' if apply else 'Would remove unused'} image {pin}")
        if apply:
            # Docker refuses removal while any container still references the image.
            run(["docker", "image", "rm", "--", pin], quiet=True, timeout=60)



def parse_version(version, manifest_path):
    match = version_re.fullmatch(version)
    if not match:
        raise ValueError(f"invalid release version in {manifest_path}: {version!r}")
    prerelease = match.group(4)
    if prerelease is None:
        pre_key = (1,)
    else:
        identifiers = []
        for part in prerelease.split("."):
            if part.isdigit():
                if len(part) > 1 and part.startswith("0"):
                    raise ValueError(
                        f"invalid numeric prerelease identifier in {manifest_path}: {part!r}"
                    )
                identifiers.append((0, int(part)))
            else:
                identifiers.append((1, part))
        pre_key = (0, *identifiers)
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)), pre_key)


def read_manifest(path, require_upgrade_script):
    manifest_path = Path(path)
    bundle = manifest_path.parent
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError(f"release manifest is missing or unsafe: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != 1:
        raise ValueError(f"unsupported release manifest schema in {manifest_path}")
    version = manifest.get("release_version", "")
    version_key = parse_version(version, manifest_path)
    revision = manifest.get("source_revision", "")
    if not revision_re.fullmatch(revision):
        raise ValueError(f"invalid source revision in {manifest_path}")
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        raise ValueError(f"release manifest has no file inventory: {manifest_path}")
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
                "selfhost/network-subnet.py",
                "selfhost/rotate-secret.sh",
                "selfhost/docs/DEPLOYMENT-COMPATIBILITY.md",
                "selfhost/docs/SECRET-ROTATION.md",
                "selfhost/docs/UNINSTALL-DATA-DELETION.md",
            }
        )
    missing = sorted(required - set(files))
    if missing:
        raise ValueError(
            f"release manifest omits required files in {manifest_path}: {', '.join(missing)}"
        )
    for relative_text, expected in sorted(files.items()):
        if not isinstance(relative_text, str) or not isinstance(expected, str):
            raise ValueError(f"malformed file inventory entry in {manifest_path}")
        relative = PurePosixPath(relative_text)
        if relative.is_absolute() or ".." in relative.parts or relative.as_posix() != relative_text:
            raise ValueError(f"unsafe file path in {manifest_path}: {relative_text!r}")
        if not digest_re.fullmatch(expected):
            raise ValueError(f"invalid checksum for {relative_text} in {manifest_path}")
        candidate = bundle.joinpath(*relative.parts)
        if not candidate.is_file() or candidate.is_symlink():
            raise ValueError(f"release file is missing or unsafe: {candidate}")
        actual = file_sha256(candidate)
        if actual != expected:
            raise ValueError(
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
                raise ValueError(f"unsafe symlink in new release: {entry}")
            if entry.is_file():
                relative = entry.relative_to(bundle).as_posix()
                if relative != "release-manifest.json":
                    actual_files.add(relative)
            elif not entry.is_dir():
                raise ValueError(f"unsupported file type in new release: {entry}")
        inventory_files = set(files)
        if actual_files != inventory_files:
            unlisted = sorted(actual_files - inventory_files)
            absent = sorted(inventory_files - actual_files)
            details = []
            if unlisted:
                details.append("unlisted files: " + ", ".join(unlisted[:10]))
            if absent:
                details.append("missing files: " + ", ".join(absent[:10]))
            raise ValueError(
                f"new release file inventory is not exact in {manifest_path}: "
                + "; ".join(details)
            )

    settings = read_env(bundle / "selfhost" / ".env.example")
    env = {key: value(settings, key) for key in settings}
    if env.get("RELEASE_VERSION") != version:
        raise ValueError(
            f"manifest version does not match selfhost/.env.example in {manifest_path}"
        )
    images = manifest.get("images")
    expected_images = {
        "backend": env.get("BACKEND_IMAGE"),
        "frontend": env.get("SELFHOST_FRONTEND_IMAGE"),
        "caddy": env.get("CADDY_IMAGE"),
    }
    if images != expected_images:
        raise ValueError(
            f"manifest image inventory does not match selfhost/.env.example in {manifest_path}"
        )
    return manifest, version_key



def release_command(directory, project, names):
    files = [directory / name for name in names]
    environment = os.environ.copy()
    env_file = directory / ".env"
    for path in [env_file, *files]:
        require(path.is_file() and not path.is_symlink(),
                f"validated Compose file is missing or unsafe: {path}")
        text = path.read_text()
        keys = re.findall(r"^\s*#?\s*([A-Z][A-Z0-9_]*)=", text, re.M)
        keys += re.findall(r"\$\{([A-Z][A-Z0-9_]*)", text)
        for key in keys:
            environment.pop(key, None)
    environment = {key: val for key, val in environment.items() if not key.startswith("COMPOSE_")}
    environment.update(CHRONICLE_HOST_UID=str(os.getuid()), CHRONICLE_HOST_GID=str(os.getgid()))
    return (["docker", "compose", "--env-file", str(env_file), "--project-name", project,
             *[arg for path in files for arg in ("-f", str(path))]], environment)


def compose_release(directory, project, names, *args, **kwargs):
    command, environment = release_command(directory, project, names)
    return run([*command, *args], cwd=directory, env=environment, **kwargs)


def dashboard_login_settings(settings, names):
    if value(settings, "DASHBOARD_EXPOSURE") == "internal" or any(
            name.endswith("-internal.yml") or name == "overlays/mode-local-https.yml" for name in names):
        require(value(settings, "DASHBOARD_PASSWORD_HASH").startswith("$2"),
                "internal dashboard requires a bcrypt DASHBOARD_PASSWORD_HASH; run ./chronicle setup to choose a dashboard password before retrying")
        return {"TESTING_LOGIN_ENABLED": "false", "REQUIRE_MFA": "false"}
    return {}


def migrate_dashboard_login(directory):
    path = Path(directory) / ".env"
    settings = read_env(path)
    updates = dashboard_login_settings(settings, compose_names(settings, Path(directory)))
    if all(value(settings, key) == val for key, val in updates.items()):
        return False
    lines = [line for line in path.read_text().splitlines()
             if not (assignment.match(line) and assignment.match(line)[1] in updates)]
    write_text(path, "\n".join([*lines, *(f"{key}={val}" for key, val in updates.items())]) + "\n")
    return True


def merge_env(old, template, destination, state, names, preserve_images=False):
    old = dict(old, CHRONICLE_STATE_DIR=quote_env(str(state)), COMPOSE_FILE=":".join(names))
    if not preserve_images:
        old.update(dashboard_login_settings(old, names))
    gateway = compose_gateway(value(old, "CHRONICLE_SUBNET", "172.28.0.0/16")) + "/32"
    if "overlays/mode-behind-proxy-internal.yml" in names and loopback_networks(value(old, "CADDY_TRUSTED_PROXIES")):
        if ipaddress.ip_address(value(old, "HTTP_BIND", "127.0.0.1").strip("[]")).is_loopback:
            proxies = gateway
        else:
            proxies = value(old, "POOL_ALLOWED_IPS")
            if proxies:
                require(all(ipaddress.ip_network(cidr).prefixlen > 0 for cidr in proxies.split())
                        and not loopback_networks(proxies), "POOL_ALLOWED_IPS must contain explicit non-loopback F5 source CIDRs")
            else:
                proxies = value(old, "CADDY_TRUSTED_PROXIES")
        old["CADDY_TRUSTED_PROXIES"] = quote_env(proxies)
        print(f"Legacy CADDY_TRUSTED_PROXIES: {proxies}; client XFF remains optional.")
    if (ipaddress.ip_address(value(old, "INTERNAL_BIND", "127.0.0.1").strip("[]")).is_loopback
            and loopback_networks(value(old, "DASHBOARD_ALLOWED_IPS"))):
        old["DASHBOARD_ALLOWED_IPS"] = quote_env(gateway + " " + value(old, "DASHBOARD_ALLOWED_IPS"))
        print("Added the Compose gateway to the legacy loopback dashboard allowlist.")
    managed = {"RELEASE_VERSION", "POSTGRES_IMAGE", "COMPOSE_FILE", "CHRONICLE_STATE_DIR"}
    rendered, seen = [], set()
    for line in template.splitlines():
        match = assignment.match(line)
        if match:
            key = match[1]
            require(key not in seen, f"new .env.example contains duplicate assignment: {key}")
            seen.add(key)
            if key in {"CHRONICLE_STATE_DIR", "COMPOSE_FILE"} or (
                    key in old and (preserve_images or (key not in managed and not key.endswith("_IMAGE")))):
                line = f"{key}={old[key]}"
        rendered.append(line)
    unknown = sorted(key for key in old.keys() - seen - managed
                     if not key.startswith("COMPOSE_") and not key.endswith("_IMAGE"))
    if unknown:
        rendered.extend(["", "# Previous operator settings not present in this release template."])
        rendered.extend(f"{key}={old[key]}" for key in unknown)
    content = "\n".join(rendered) + "\n"
    require(preserve_images or "__CHRONICLE_" not in content,
            "new .env.example still contains unresolved release image placeholders")
    if destination is not None:
        write_text(destination, content)
    return content


def postgres_major(version_text, image):
    match = re.search(r"PostgreSQL\)?\s+([0-9]+)", version_text)
    require(match, f"could not parse the PostgreSQL version in {image}")
    return int(match[1])


def postgres_sql(container, query):
    result = run(["docker", "exec", container, "/bin/bash", "-ceu",
                  'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "${POSTGRES_USER:-chronicle}" '
                  '-d "${POSTGRES_DB:-chronicle}" -tAqc "' + query + '"'],
                 capture=True, check=True)
    return result.stdout.strip()


def require_no_encrypted_collection(container, outcome, action):
    checks = (("SELECT CASE WHEN EXISTS (SELECT 1 FROM studies WHERE settings #> "
               "'{Encryption,enabled}' = 'true'::JSONB) THEN 'blocked' ELSE 'clear' END",
               ("clear", "blocked"), "study-encryption"),
              ("SELECT CASE WHEN to_regclass('public.encrypted_payloads') IS NULL "
               "THEN 'absent' ELSE 'present' END", ("absent", "present"), "encrypted-payload"))
    values = []
    for query, expected, label in checks:
        try:
            result = postgres_sql(container, query)
        except subprocess.SubprocessError:
            raise ValueError(f"could not evaluate the {label} upgrade precondition; {outcome}") from None
        require(result in expected, f"{label} preflight returned an invalid result; {outcome}")
        values.append(result)
    payloads = "clear"
    if values[1] == "present":
        try:
            payloads = postgres_sql(container, "SELECT CASE WHEN EXISTS (SELECT 1 FROM encrypted_payloads) "
                                   "THEN 'blocked' ELSE 'clear' END")
        except subprocess.SubprocessError:
            raise ValueError(f"could not inspect historical encrypted payloads; {outcome}") from None
        require(payloads in ("clear", "blocked"), f"encrypted-payload preflight returned an invalid row result; {outcome}")
    require(values[0] == payloads == "clear",
            "this release cannot safely export study-encrypted collection data. " + outcome.capitalize() +
            f". Keep the previous release running; do not delete ciphertext to force the {action}. "
            "Complete an approved decrypt-and-export migration plan, then retry. See docs/UPGRADE-ROLLBACK.md.")


ROLLBACK_DUMP = ('PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h 127.0.0.1 '
                 '-U "${POSTGRES_USER:-chronicle}" -d "${POSTGRES_DB:-chronicle}" '
                 '--no-owner --exclude-schema=chronicle_restore_continuity')


def rollback_dump(command, path, **kwargs):
    with path.open("xb") as output:
        path.chmod(0o600)
        fcntl.flock(output, fcntl.LOCK_EX)
        with subprocess.Popen(command, stdout=subprocess.PIPE, **kwargs) as dump:
            try:
                with gzip.GzipFile(fileobj=output, mode="wb") as compressed:
                    shutil.copyfileobj(dump.stdout, compressed)
                require(dump.wait() == 0, "database dump failed")
            finally:
                dump.stdout.close()
                if dump.poll() is None:
                    dump.terminate()
            dump.wait()
        output.flush()
        os.fsync(output.fileno())
    validate_dump(path)
    return file_sha256(path)
