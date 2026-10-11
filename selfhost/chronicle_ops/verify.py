"""Probe the configured public and internal exposure boundaries."""

from concurrent.futures import ThreadPoolExecutor
import getpass
from http.cookiejar import MozillaCookieJar
import ipaddress
import json
import os
import plistlib
from pathlib import Path
import secrets
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

from .common import BLD, GRN, RED, RST, YEL, authority, compose, dashboard_ca, dashboard_origin, run
from .dump import BACKUP_SCRATCH_FACTOR, DumpError, validate_dump, verified_backup
from .release import postgres_sql, read_env, require, value

BACKUP_COMPRESSION_ESTIMATE = 0.20
WAL_WARNING_FACTOR = 2
METRICS_MAX_AGE_SECONDS = 120
RATE_LIMIT_PROBE_WORKERS = 32
RATE_LIMIT_PROBE_MAX_REQUESTS = 400
MONITORING_JOBS = {"chronicle-backend", "chronicle-containers", "chronicle-host", "chronicle-operational",
                   "chronicle-log-forwarder", "chronicle-operations", "chronicle-configuration"}

DATABASE_PRIVILEGES_SQL = """
SELECT NOT EXISTS (
    SELECT 1 FROM (VALUES
        ('chronicle_app', 'audit', 'SELECT,UPDATE,DELETE,TRUNCATE'),
        ('chronicle_app', 'audit_buffer', 'SELECT,UPDATE,DELETE,TRUNCATE'),
        ('chronicle_admin', 'audit', 'UPDATE,DELETE,TRUNCATE'),
        ('chronicle_admin', 'audit_buffer', 'UPDATE,DELETE,TRUNCATE'),
        ('chronicle_app', 'data_deletion_audit_outbox', 'DELETE,TRUNCATE'),
        ('chronicle_app', 'restore_continuity_reconciliations', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'),
        ('chronicle_admin', 'restore_continuity_reconciliations', 'INSERT,UPDATE,DELETE,TRUNCATE')
    ) AS forbidden(role_name, table_name, privileges)
    WHERE to_regclass('public.' || table_name) IS NULL
       OR has_table_privilege(role_name, to_regclass('public.' || table_name), privileges)
) AND NOT EXISTS (
    SELECT 1 FROM (VALUES
        ('chronicle_app', 'studies', 'SELECT'),
        ('chronicle_app', 'audit', 'INSERT')
    ) AS required(role_name, table_name, privilege)
    WHERE to_regclass('public.' || table_name) IS NULL
       OR NOT has_table_privilege(role_name, to_regclass('public.' || table_name), privilege)
)
""".strip()


def verify_database_privileges():
    container = compose("ps", "-q", "postgres", capture=True, check=True).stdout.strip()
    require(container and postgres_sql(container, DATABASE_PRIVILEGES_SQL) == "t",
            "database runtime privileges violate audit/restore least privilege; recover a backup that preserves ACLs")


def capacity_checks(settings, backups):
    command = ('df -Pk "$PGDATA"; '
               'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -qAt -h 127.0.0.1 '
               '-U "${POSTGRES_USER:-chronicle}" -d "${POSTGRES_DB:-chronicle}" -c '
               "\"SELECT json_build_object('database_bytes',pg_database_size(current_database()),"
               "'wal_bytes',(SELECT coalesce(sum(size),0) FROM pg_ls_waldir()),"
               "'max_wal_bytes',pg_size_bytes(current_setting('max_wal_size')))\"")
    result = compose("exec", "-T", "postgres", "/bin/bash", "-ceu", command, capture=True, timeout=15, check=True)
    lines = result.stdout.splitlines()
    data = json.loads(lines[-1])
    free = int(lines[-2].split()[3]) * 1024
    free_percent = 100 - int(lines[-2].split()[4].rstrip("%"))
    enough = free_percent >= 15
    rows = [("database-disk", "ok" if enough else "fail",
             f"Database volume has {free_percent}% free",
             "none" if enough else "Free space on the database volume, then run ./chronicle up and verify ingest")]
    database = value(settings, "POSTGRES_DB", "chronicle")
    dump_size = int(data["database_bytes"] * BACKUP_COMPRESSION_ESTIMATE)
    uncompressed = data["database_bytes"]
    try:
        path, marker = verified_backup(backups, database)
        dump_size = path.stat().st_size
        uncompressed = max(uncompressed, validate_dump(path))
    except (OSError, ValueError, KeyError):
        pass
    reserve = BACKUP_SCRATCH_FACTOR * uncompressed
    wal = ("postgres-wal", "warn" if data["wal_bytes"] > WAL_WARNING_FACTOR * data["max_wal_bytes"] else "ok",
           f"pg_wal uses {data['wal_bytes']} bytes; soft max_wal_size is {data['max_wal_bytes']}", "Inspect replication slots and long transactions; never delete WAL files")
    if "overlays/backups.yml" not in value(settings, "COMPOSE_FILE"):
        return rows + [wal]
    rows.append(("backup-reserve", "ok" if free >= reserve else "fail",
                 f"Next restore-check needs {reserve} additional bytes; database filesystem has {free}", "Add database capacity before the next backup"))
    count = sum(int(value(settings, key, default)) for key, default in
                (("BACKUP_KEEP_DAYS", "14"), ("BACKUP_KEEP_WEEKS", "8"), ("BACKUP_KEEP_MONTHS", "6"))) + 1
    unique = {}
    for directory in ("last", "daily", "weekly", "monthly"):
        for path in (Path(backups) / directory).glob(database + "-*.sql.gz"):
            info = path.stat()
            unique[info.st_dev, info.st_ino] = info.st_size
    projected = count * dump_size
    additional = max(0, projected - sum(unique.values()))
    backup_free = os.statvfs(backups).f_bavail * os.statvfs(backups).f_frsize
    rows.append(("backup-footprint", "ok" if backup_free >= additional else "warn",
                 f"Retention projects {projected} bytes ({count} dumps); needs {additional} more; backup filesystem has {backup_free}", "Reduce reviewed retention or add backup capacity"))
    rows.append(wal)
    return rows


def healthy_targets(payload, now=None):
    targets = payload.get("data", {}).get("activeTargets", [])
    now = time.time() if now is None else now
    jobs = set()
    from datetime import datetime
    for target in targets:
        job = target.get("labels", {}).get("job")
        if job not in MONITORING_JOBS:
            continue
        try:
            age = now - datetime.fromisoformat(target["lastScrape"].replace("Z", "+00:00")).timestamp()
        except (ValueError, KeyError):
            return False
        if target.get("health") != "up" or not 0 <= age <= METRICS_MAX_AGE_SECONDS:
            return False
        jobs.add(job)
    return jobs == MONITORING_JOBS


def monitoring_checks():
    result = compose("exec", "-T", "grafana", "wget", "-T", "8", "-qO-", "http://victoriametrics:8428/api/v1/targets", capture=True, timeout=15)
    metrics_ok = result.returncode == 0 and healthy_targets(json.loads(result.stdout))
    daemons_ready = all(compose("exec", "-T", "grafana", "wget", "-T", "8", "-q", "--spider", endpoint,
                               quiet=True, timeout=15).returncode == 0 for endpoint in
                        ("http://victoriametrics:8428/-/healthy", "http://victorialogs:9428/health", "http://fluent-bit:2020/api/v1/health"))
    metrics_ok &= daemons_ready
    # The existing operator-event tail path exercises Fluent Bit's redaction and delivery.
    category = "doctor_" + secrets.token_hex(8)
    compose("exec", "-T", "operational-probe", "/monitoring/record-operation.sh", "doctor", "success", category, check=True, timeout=15)
    deadline, delivered = time.monotonic() + 30, False
    while time.monotonic() < deadline:
        result = compose("exec", "-T", "grafana", "wget", "-T", "8", "-qO-",
                         "http://victorialogs:9428/select/logsql/query?query=failure_category%3A" + category,
                         capture=True, timeout=15)
        if result.returncode == 0 and category in result.stdout:
            delivered = True
            break
        time.sleep(2)
    return [("metrics-pipeline", "ok" if metrics_ok else "fail", "All required scrape targets and daemons are healthy and fresh" if metrics_ok else "A required target/daemon is missing, stale or unhealthy", "Inspect failed or missing VictoriaMetrics targets"),
            ("logs-pipeline", "ok" if delivered else "fail", "Redacted doctor canary traverses Fluent Bit to VictoriaLogs" if delivered else "Redacted canary was not delivered", "Inspect Fluent Bit tail input and delivery")]


def verify_backup_storage(backups, waiver=""):
    path = Path(backups).resolve()
    while not path.exists() and path != path.parent:
        path = path.parent
    encrypted = False
    try:
        if sys.platform == "darwin":
            device = run(["df", "-P", str(path)], capture=True)
            if device.returncode == 0:
                info = run(["diskutil", "info", "-plist", device.stdout.splitlines()[-1].split()[0]], capture=True)
                if info.returncode == 0:
                    data = plistlib.loads(info.stdout.encode())
                    encrypted = data.get("FileVault") is True or data.get("Encrypted") is True
        else:
            mount = run(["findmnt", "-n", "-o", "SOURCE", "-T", str(path)], capture=True)
            if mount.returncode == 0:
                device = mount.stdout.strip().split("[", 1)[0]
                devices = run(["lsblk", "--inverse", "--tree", "--json", "--output", "TYPE", device], capture=True)
                if devices.returncode == 0:
                    roots = json.loads(devices.stdout)["blockdevices"]
                    encrypted = bool(roots)
                    pending = [(entry, False) for entry in roots]
                    while pending:
                        entry, covered = pending.pop()
                        covered |= entry["type"] == "crypt"
                        children = entry.get("children", [])
                        if children:
                            pending.extend((child, covered) for child in children)
                        elif not covered:
                            encrypted = False
    except (OSError, ValueError, KeyError, IndexError, TypeError):
        pass
    if encrypted:
        print(f"  {GRN}ok{RST}   backup backing device is encrypted")
        return 0
    if waiver.strip() and "CHANGE_ME" not in waiver and not any(c in waiver for c in "\r\n"):
        print(f"  {YEL}warn{RST} backup encryption uses a reviewed waiver; consult BACKUP_STORAGE_ENCRYPTION_WAIVER in the controlled register")
        return 0
    print(f"  {YEL}warn{RST} backup backing-device encryption is unconfirmed; enable it or record a reviewed BACKUP_STORAGE_ENCRYPTION_WAIVER")
    return 1


def verify_backup(backups, database=None):
    if database is not None:
        try:
            verified_backup(backups, database)
            print(f"  {GRN}ok{RST}   active database has a fresh restore-verified dump")
            return 0
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f"  {RED}FAIL{RST} verified backup unavailable: {error}")
            return 1
    candidates = sorted((Path(backups) / "last").glob("*.sql.gz"))
    if not candidates:
        print(f"  {RED}FAIL{RST} no SQL dump yet — nothing recoverable if the keyring is lost")
        return 1
    for path in candidates:
        try:
            validate_dump(path)
        except (OSError, DumpError) as error:
            print(f"  {RED}FAIL{RST} SQL dump {error}: {path}")
            return 1
    print(f"  {GRN}ok{RST}   a key-free SQL dump exists (restores without pg_tde)")
    return 0


def curl_config(name, text):
    if "\n" in text or "\r" in text:
        raise ValueError("credential must not contain a line break")
    return '{} = "{}"\n'.format(name, text.replace("\\", "\\\\").replace('"', '\\"'))


def curl(url, *args, config=None, timeout=10):
    parsed = urlsplit(url)
    settings = read_env(Path.cwd() / ".env") if (Path.cwd() / ".env").is_file() else {}
    management = dashboard_origin(settings)
    trust = []
    if parsed.scheme == "https" and (url.startswith(management + "/") or "mode-local-https.yml" in value(settings, "COMPOSE_FILE")):
        tls = Path(os.environ.get("CHRONICLE_OPS_STATE", ".")) / "tls"
        certificate = dashboard_ca(tls) if url.startswith(management + "/") else tls / "local-ca.crt"
        trust = ["--cacert", str(certificate)]
    result = run(["curl", *trust, *(["--config", "-"] if config is not None else []),
                  "--noproxy", "*", "--silent", "--show-error", "--max-time", str(timeout), *args, url],
                 capture=True, input=config)
    return result.returncode, (result.stdout or "").rstrip("\n")


def verify_public_origin(origin):
    if urlsplit(origin).scheme != "https":
        print("public acceptance requires an HTTPS origin", file=sys.stderr)
        return 1
    for path, expected in (("/health", "204"), ("/chronicle/", "200")):
        status, response = curl(origin.rstrip("/") + path, "-o", "/dev/null", "-w", "%{http_code}")
        if status or response != expected:
            print(f"public HTTPS {path} failed ({response}); check DNS, LB routing and released-client TLS trust", file=sys.stderr)
            return 1
    return 0


def check_proxy_http_redirect(http_url, expected_location):
    status, response = curl(http_url, "--connect-timeout", "5", "--dump-header", "-",
                            "-o", "/dev/null", "-w", "\n%{http_code}")
    lines = response.replace("\r", "").splitlines()
    code = lines[-1] if lines else ""
    locations = [line.split(":", 1)[1].strip() for line in lines if line.lower().startswith("location:")]
    return code if status == 0 and code in ("301", "302", "307", "308") and locations and locations[-1] == expected_location else None


def dashboard_session(origin, password):
    config = ""
    with tempfile.TemporaryDirectory(prefix="chronicle-session-") as folder:
        cookies = str(Path(folder) / "session")
        status, response = curl(origin + "/chronicle/v3/auth/dashboard-login", "--cookie-jar", cookies,
                                "-H", "Content-Type: application/json", "-H", "Origin: " + origin,
                                "-w", "\n%{http_code}", timeout=15,
                                config=config + curl_config("data-binary", json.dumps({"password": password})))
        body, _, code = response.rpartition("\n")
        try:
            login = json.loads(body)
            if status or code != "200" or login.get("authenticated") is not True or not login.get("csrfToken"):
                return False, code
            status, response = curl(origin + "/chronicle/v3/auth/session", "--cookie", cookies, "--cookie-jar", cookies,
                                    "-H", "Origin: " + origin, "-w", "\n%{http_code}", config=config)
            body, _, code = response.rpartition("\n")
            session = json.loads(body)
            # /session reissues the CSRF cookie; the token it returns must be the one it set.
            jar = MozillaCookieJar(cookies)
            jar.load(ignore_discard=True, ignore_expires=True)
            issued = next((cookie.value for cookie in jar if cookie.name == "ol_csrf_token"), None)
            return (status == 0 and code == "200" and session.get("authenticated") is True
                    and bool(issued) and session.get("csrfToken") == issued), code
        except (OSError, ValueError, AttributeError):
            return False, code


def verify(args):
    dashboard_password = os.environ.pop("DASHBOARD_PASSWORD", "")
    if args:
        if dashboard_password:
            raise ValueError("use either --dashboard-password or DASHBOARD_PASSWORD, not both")
        if sys.stdin.isatty():
            dashboard_password = getpass.getpass("Dashboard password: ")
        else:
            line = sys.stdin.readline()
            if not line:
                raise ValueError("--dashboard-password expected one password line on stdin")
            dashboard_password = line.rstrip("\n")
        if not dashboard_password:
            raise ValueError("dashboard password must not be empty")
    settings = read_env(Path.cwd() / ".env")
    def setting(key, default=""):
        return value(settings, key, default)
    if "CHRONICLE_OPS_STATE" in os.environ:
        require((Path.cwd() / (setting("CHRONICLE_STATE_DIR") or ".")).resolve() ==
                Path(os.environ["CHRONICLE_OPS_STATE"]).resolve(),
                "state directory changed while acquiring the lock; retry verification")
        require(setting("COMPOSE_PROJECT_NAME", "chronicle-selfhost") == os.environ["CHRONICLE_OPS_PROJECT"],
                "Compose project changed while acquiring the lock; retry verification")
    os.environ["COMPOSE_FILE"] = setting("COMPOSE_FILE")
    dashboard_password = value(settings, "DASHBOARD_PASSWORD") or dashboard_password
    mode = next((name.removeprefix("overlays/mode-").removesuffix(".yml").removesuffix("-internal")
                 for name in setting("COMPOSE_FILE").split(":") if name.startswith("overlays/mode-")), "")
    exposure = "internal" if mode in ("behind-proxy", "own-tls", "local-https") else ""
    bind = setting("HTTP_BIND", "127.0.0.1")
    external = setting("CHRONICLE_PUBLIC_BASE_URL") or "https://" + setting("DOMAIN")
    pub = external
    retry_sleep = float(setting("RATE_LIMIT_RETRY_SLEEP", "1.2"))
    failed = False

    def report(ok, message):
        nonlocal failed
        print(f"  {GRN if ok else RED}{'ok' if ok else 'FAIL'}{RST}   {message}")
        failed |= not ok

    def hit(origin, path, served=False):
        code = "000"
        for _ in range(4):
            _, code = curl(origin + path, *(["-L"] if served else []), "-o", "/dev/null", "-w",
                           "%{http_code} %{size_download}" if served else "%{http_code}")
            if code.split(" ")[0] != "429":
                break
            time.sleep(retry_sleep)
        return code

    def probe(path, expected, label="", origin=pub, served=False):
        response = hit(origin, path, served)
        code, _, size = response.partition(" ")
        ok = code in expected and (not served or (size.isdigit() and int(size) > 0))
        wanted = "reachable" if len(expected) == 3 else " or ".join(expected)
        detail = "" if ok else (f"served {size or '0'} bytes (expected 200 and a page) "
                                if served else f"(expected {wanted}) ")
        report(ok, f"{code:<3} {path} " + detail + label)


    print(f"{BLD}Public surface{RST} ({pub})")
    probe("/health", ("204",), "ready")
    probe("/chronicle", ("200",), "dashboard (the path the README gives operators)", served=True)
    probe("/chronicle/", ("200",), "dashboard assets", served=True)
    probe("/chronicle/survey", ("200",), "participant form")
    for path, label in (("/chronicle/v4/study/x/upload", "mobile upload reachable"),
                        ("/chronicle/study/x", "legacy mobile API reachable")):
        probe(path, ("200", "401", "403"), label)
    for path in ("/chronicle/datastore/", "/chronicle/principal/", "/chronicle/compliance/", "/chronicle/import/", "/prometheus/"):
        probe(path, ("404",), "direct backend route blocked")
    if exposure == "internal":
        print(f"\n{BLD}Public surface must NOT expose the dashboard{RST}")
        for path in ("/chronicle/v3/auth/testing-login", "/chronicle/v3/auth/session", "/chronicle/v3/auth/oidc/login",
                     "/chronicle/api/web/study", "/chronicle/v3/time-use-diary/S/data", "/chronicle/v3/survey/S/questionnaire/Q/responses"):
            probe(path, ("404",))
        internal = dashboard_origin({key: setting(key) for key in ("DASHBOARD_BASE_URL", "INTERNAL_BIND", "INTERNAL_PORT")})
        print(f"\n{BLD}Internal surface{RST} ({internal})")
        status, _ = curl(internal + "/health", "-o", "/dev/null")
        report(status == 0, "internal listener is HTTPS (credentials are not sent in clear)" if not status else "internal listener did not answer over HTTPS")
        _, code = curl(internal + "/chronicle/api/web/study", "-o", "/dev/null", "-w", "%{http_code}")
        loopback_management = ipaddress.ip_address(setting("INTERNAL_BIND", "127.0.0.1").strip("[]")).is_loopback
        source_rejected = code == "403" and not loopback_management
        if source_rejected:
            print(f"  {YEL}--{RST} host is outside the researcher ACL; remote researcher acceptance is required")
        report(code == "401" or source_rejected, f"dashboard API requires an app session ({code})")
        if not source_rejected:
            authenticated, code = dashboard_session(internal,
                                                    "not-the-" + secrets.token_hex(4) + "-password")
            report(not authenticated and code == "401", f"wrong dashboard password is rejected ({code})")
        cors = compose("exec", "-T", "backend", "grep", "-qF", '"' + internal + '"', "/server/rendered-config/cors.yaml", quiet=True)
        report(cors.returncode == 0, "the dashboard origin is on the API allowlist" if not cors.returncode else f"the dashboard origin {internal} is not on the API allowlist — sign-in cannot complete.\n       Add it to DASHBOARD_ORIGINS in .env and run ./chronicle up again.")
        if dashboard_password and not source_rejected:
            deadline = time.monotonic() + 75
            while True:
                authenticated, code = dashboard_session(internal, dashboard_password)
                if code != "429" or time.monotonic() >= deadline:
                    break
                time.sleep(15)
            report(authenticated, "backend issued an authenticated dashboard session and accepted its cookie" if authenticated else f"dashboard session contract failed ({code})")
        else:
            print(f"  {YEL}--{RST}   rerun with --dashboard-password to also check the correct password")
    print(f"\n{BLD}Public mobile bootstrap{RST}")
    settings_path = "/chronicle/v3/study/00000000-0000-0000-0000-000000000000/settings/type/DataCollection"
    enrollment_path = "/chronicle/v4/study/00000000-0000-0000-0000-000000000000/participant/reviewer/enroll"
    reviewer_path = "/chronicle/v4/mobile/reviewer-enrollment"
    _, settings_code = curl(pub + settings_path, "-o", "/dev/null", "-w", "%{http_code}")
    device = {"@class": "com.openlattice.chronicle.sources.AndroidDevice",
              **dict.fromkeys(("device", "model", "codename", "brand", "product", "deviceId"), "selfhost-verifier"),
              "osVersion": "1", "sdkVersion": "1"}
    _, enrollment_code = curl(pub + enrollment_path, "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST",
                              "-H", "Content-Type: application/json", "-H", "X-Chronicle-Device-Id: selfhost-verifier",
                              "--data", json.dumps(device, separators=(",", ":")))
    _, reviewer_code = curl(pub + reviewer_path, "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST")
    _, page = curl(pub + "/reviewer", "-L", "-o", "/dev/null", "-w", "%{http_code}|%{url_effective}|%{size_download}")
    parts = page.split("|")
    page_ok = len(parts) == 3 and parts[:2] == ["200", pub + "/chronicle/reviewer"] and parts[2].isdigit() and int(parts[2]) > 0
    report(page_ok, f"/reviewer reaches the anonymous Chronicle page ({pub}/chronicle/reviewer)" if page_ok else f"/reviewer did not reach a nonempty anonymous Chronicle page ({page})")
    reachable = settings_code.startswith("2") or settings_code in ("400", "404", "409", "422")
    if settings_code in ("000", "401", "403"):
        reason = "public collection settings are unavailable without a global app secret"
    elif settings_code.startswith("5"):
        reason = "public collection settings returned a server error"
    else:
        reason = "public collection settings are reachable" if reachable else "public collection settings returned an unexpected status"
    report(reachable, f"{reason} ({settings_code})")
    enrollment_ok = enrollment_code in ("401", "403")
    enrollment_message = (f"enrollment without a one-time code is refused ({enrollment_code})" if enrollment_ok else
                          "enrollment endpoint did not answer" if enrollment_code == "000" else
                          f"enrollment without a one-time code was not refused ({enrollment_code})")
    report(enrollment_ok, enrollment_message)
    reviewer_ok = reviewer_code in ("401", "403", "404")
    reviewer_message = ("exact reviewer route refuses requests without its credential" if reviewer_ok else
                        "exact reviewer route returned a server error" if reviewer_code.startswith("5") else
                        "exact reviewer route accepted an unauthenticated request")
    report(reviewer_ok, f"{reviewer_message} ({reviewer_code})")
    if setting("CHRONICLE_REVIEWER_ACCESS_ENABLED", "false") == "true":
        config = curl_config("header", "X-Chronicle-Reviewer-Secret: " + value(settings, "CHRONICLE_REVIEWER_ACCESS_SECRET"))
        _, code = curl(pub + reviewer_path, "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST", config=config)
        report(code == "200", "reviewer bootstrap minted a fresh one-time invitation with the configured credential" if code == "200" else f"reviewer bootstrap rejected the configured credential ({code})")
    else:
        print(f"  {YEL}--{RST}   reviewer bootstrap is disabled; authenticated mint probe skipped")
    print(f"\n{BLD}Rate limiting{RST}")
    events = int(setting("RATE_LIMIT_MOBILE_ABUSE_EVENTS", "200"))
    require(events > 0, "RATE_LIMIT_MOBILE_ABUSE_EVENTS must be positive")
    # Trusted SNAT has a fleet-sized edge ceiling; the backend still limits anonymous traffic.
    burst = min(events * 2, RATE_LIMIT_PROBE_MAX_REQUESTS)
    with ThreadPoolExecutor(max_workers=min(RATE_LIMIT_PROBE_WORKERS, burst)) as pool:
        codes = list(pool.map(lambda _: curl(pub + "/chronicle/v4/study/x/upload", "-o", "/dev/null", "-w", "%{http_code}")[1], range(burst)))
    report("429" in codes, "mobile abuse is rate limited by the edge or backend" if "429" in codes else f"{burst} requests to mobile ingest were never rate limited")
    time.sleep(retry_sleep)
    try:
        verify_database_privileges()
        report(True, "database runtime roles retain audit and restore privilege restrictions")
    except (OSError, ValueError, subprocess.SubprocessError):
        report(False, "could not verify database audit and restore privilege restrictions")
    backups = Path(os.environ["CHRONICLE_OPS_BACKUPS"])
    if "overlays/backups.yml" in setting("COMPOSE_FILE"):
        verify_backup_storage(backups, setting("BACKUP_STORAGE_ENCRYPTION_WAIVER"))
    if "overlays/backups.yml" in setting("COMPOSE_FILE") and backups.is_dir():
        print(f"\n{BLD}Database dumps{RST}")
        mode_bits = stat.S_IMODE(backups.stat().st_mode)
        report(mode_bits == 0o700, f"{backups} is 0700 — dumps are not readable by other local accounts" if mode_bits == 0o700 else f"{backups} is {mode_bits:o} — every local account can read the full database (want 0700)")
        unwritable = sum(not os.access(directory, os.W_OK) for directory in [backups, *backups.iterdir()] if directory.is_dir())
        report(unwritable == 0, "dumps belong to this account — they can be pruned and copied without sudo" if not unwritable else f"{unwritable} director(y/ies) under {backups} are not writable by this account — backups cannot be pruned without sudo")
    if "overlays/backups.yml" in setting("COMPOSE_FILE"):
        failed |= bool(verify_backup(backups, setting("POSTGRES_DB", "chronicle")))
    if setting("ENABLE_ENCRYPTION", "true") == "true":
        print(f"\n{BLD}Encryption at rest{RST}")
        counts = []
        for operator, fallback in (("=", "0"), ("<>", "999")):
            sql = "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_am a ON a.oid=c.relam WHERE n.nspname='public' AND c.relkind='r' AND a.amname" + operator + "'tde_heap';"
            result = compose("exec", "-T", "postgres", "/bin/bash", "-euc",
                             'IFS= read -r -d "" PGPASSWORD\nexport PGPASSWORD\n'
                             'exec psql -X -qAt -v ON_ERROR_STOP=1 -h 127.0.0.1 '
                             '-U "${POSTGRES_USER:-chronicle}" -d "${POSTGRES_DB:-chronicle}" -f -',
                             capture=True, input=value(settings, "POSTGRES_PASSWORD") + "\0" + sql + "\n")
            counts.append(result.stdout.strip() if result.returncode == 0 else fallback)
        enc, plain = counts
        report(plain == "0" and enc.isdigit() and int(enc) > 0, f"all {enc} tables are encrypted (tde_heap)" if plain == "0" and enc.isdigit() and int(enc) > 0 else f"{plain} table(s) still on plain heap")
        keyring = backups / "keyring" / "chronicle-keyring.per"
        report(keyring.is_file() and keyring.stat().st_size > 0,
               f"keyring copied into {backups}/keyring" if keyring.is_file() and keyring.stat().st_size > 0 else f"no keyring copy in {backups} — the data volume could not be remounted")

    if mode == "behind-proxy":
        probe("/health", ("204",), "public HTTPS through the LB (strict certificate validation)", origin=external)
        probe("/chronicle/", ("200",), "public HTTPS assets through the LB", origin=external, served=True)
    if mode == "behind-proxy" and setting("PUBLIC_HTTP_ENABLED", "false") == "true":
        external = external.rstrip("/")
        host = urlsplit(external).hostname
        http_authority = f"[{host}]" if host and ":" in host else host or ""
        http = "http://" + http_authority
        print(f"\n{BLD}External HTTP redirect{RST} ({http}/health)")
        code = check_proxy_http_redirect(http + "/health", external + "/health") if http_authority else None
        ok = code is not None
        report(ok, f"{code} redirects to the canonical HTTPS health URL ({external}/health)" if ok else f"HTTP /health must redirect with 301, 302, 307 or 308 to exactly {external}/health")
    print()
    if failed:
        print(f"{RED}Verification FAILED{RST} — the deployment is not exposed as configured.")
        return 1
    print(f"{GRN}Verified{RST} — exposure matches DASHBOARD_EXPOSURE={exposure}")
    if mode == "behind-proxy":
        print("Public HTTPS passed from this host. Confirm phone enrollment and dashboard sign-in from their intended networks.")
    return 0
