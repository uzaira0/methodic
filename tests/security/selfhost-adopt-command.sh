#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
mkdir -p "$HOME/tmp"
RUN_DIR=$(mktemp -d -p "$HOME/tmp" selfhost-adopt-command.XXXXXX)
trap 'rm -rf -- "$RUN_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export ADOPT_RECORD="$RUN_DIR/argv.jsonl"
export ADOPT_FAILURE=''
mkdir -p "$RUN_DIR/bin"
cat >"$RUN_DIR/bin/docker" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with open(os.environ["ADOPT_RECORD"], "a") as handle:
    handle.write(json.dumps([str(Path.cwd()), *args]) + "\n")
failure = os.environ.get("ADOPT_FAILURE")
if args[0] == "inspect":
    print("true unhealthy" if failure == "health" else "true healthy")
elif "pg_dump" in " ".join(args):
    if failure == "dump":
        sys.exit(1)
    if failure != "empty-dump":
        print("-- fixture dump\nSELECT 1;")
elif "stop" in args:
    sys.exit(1 if failure == "stop" else 0)
elif "down" in args:
    sys.exit(1 if failure == "down" else 0)
elif "up" in args:
    pass  # Source rollback only; new up/verify are intercepted by the fixture launcher.
elif args[0] == "run":
    # Stand in for the root copy container: replicate the two bind mounts' contents.
    mounts = dict(args[i + 1].split(":")[:2] for i, a in enumerate(args) if a == "-v")
    source = next(host for host, target in mounts.items() if target == "/from")
    target = next(host for host, target in mounts.items() if target == "/to")
    assert args[args.index("--user") + 1] == "0:0" and args[args.index("--entrypoint") + 1] == "/bin/cp", args
    assert args[-3:] == ["-a", "/from/.", "/to/"], args
    import shutil
    shutil.copytree(source, target, dirs_exist_ok=True)
elif "config" in args:
    print("postgres\nbackend\nweb\ndb-init\ndb-backup")
elif "ps" in args:
    if "-q" in args:
        if failure != "missing-postgres":
            print("source-postgres")
    else:
        print("postgres\nbackend" if failure == "writers-running" else "postgres")
else:
    sys.exit("Unexpected docker call: " + repr(args))
PY
chmod +x "$RUN_DIR/bin/docker"
export PATH="$RUN_DIR/bin:$PATH"

fixture() {
  rm -rf -- "$RUN_DIR/source checkout" "$RUN_DIR/release"
  : >"$ADOPT_RECORD"
  export ADOPT_FAILURE=''
  source_dir="$RUN_DIR/source checkout/selfhost"
  new_dir="$RUN_DIR/release/selfhost"
  mkdir -p "$source_dir/backups" "$source_dir/tls" "$source_dir/overlays" \
    "$new_dir/backups" "$new_dir/tls" "$new_dir/overlays"
  cp "$ROOT_DIR/selfhost/chronicle" "$new_dir/operator"
  printf '{"release_version":"1.2.3"}\n' >"$RUN_DIR/release/release-manifest.json"
  for name in docker-compose.yml overlays/mode-behind-proxy-internal.yml overlays/backups.yml; do
    touch "$source_dir/$name" "$new_dir/$name"
  done
  cat >"$source_dir/.env" <<'EOF'
COMPOSE_PROJECT_NAME='pilot-project'
COMPOSE_FILE=docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/backups.yml
CHRONICLE_STATE_DIR=.
BACKEND_IMAGE=local/backend:source
SELFHOST_FRONTEND_IMAGE=local/frontend:source
CADDY_IMAGE=local/caddy:source
POSTGRES_PASSWORD='fixture-only-password'
OPERATOR_CUSTOM='keep me'
EOF
  chmod 600 "$source_dir/.env"
  printf 'existing backup\n' >"$source_dir/backups/existing.sql"
  printf 'fixture certificate\n' >"$source_dir/tls/cert.pem"
  chmod 600 "$source_dir/tls/cert.pem"
  python3 - "$new_dir/.env.example" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text("RELEASE_VERSION=1.2.3\nCOMPOSE_PROJECT_NAME=chronicle-selfhost\n"
    "CHRONICLE_STATE_DIR=.\nCOMPOSE_FILE=docker-compose.yml\nNEW_DEFAULT=enabled\n"
    "POSTGRES_IMAGE=registry/postgres:fixture\n" +
    "".join(f"{key}=registry/{image}@sha256:{'a' * 64}\n" for key, image in
            [("BACKEND_IMAGE", "backend"), ("SELFHOST_FRONTEND_IMAGE", "frontend"), ("CADDY_IMAGE", "caddy")]))
PY
  # The real adopt runs as ./operator; its ./chronicle child calls hit this launcher.
  # This observes both invocations without a production test hook or any Docker daemon.
  cat >"$new_dir/chronicle" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
with open(os.environ["ADOPT_RECORD"], "a") as handle:
    handle.write(json.dumps([str(Path.cwd()), "chronicle", *sys.argv[1:]]) + "\n")
sys.exit(1 if os.environ.get("ADOPT_FAILURE") == sys.argv[1] else 0)
PY
  chmod +x "$new_dir/chronicle"
}

expect_failure() {
  local diagnostic=$1
  shift
  if bash "$new_dir/operator" adopt "$@" >"$RUN_DIR/output" 2>&1; then
    fail "unexpected success: $diagnostic"
  fi
  grep -Fq "$diagnostic" "$RUN_DIR/output" || { cat "$RUN_DIR/output" >&2; fail "missing diagnostic: $diagnostic"; }
}

fixture
expect_failure 'usage:'
expect_failure 'usage:' --from
expect_failure 'usage:' --wrong "$source_dir"
expect_failure 'usage:' --from "$source_dir" extra
expect_failure 'does not exist' --from "$RUN_DIR/absent"
expect_failure 'separate source checkout' --from "$new_dir"
touch "$RUN_DIR/source checkout/release-manifest.json"
expect_failure './chronicle upgrade --from' --from "$source_dir"
rm "$RUN_DIR/source checkout/release-manifest.json"
rm "$source_dir/.env"
expect_failure 'source .env must be a regular file' --from "$source_dir"
fixture
chmod 644 "$source_dir/.env"
expect_failure 'mode 0600' --from "$source_dir"
fixture
rm -r "$source_dir/backups"
expect_failure 'source backups/' --from "$source_dir"
fixture
rm -r "$source_dir/tls"
expect_failure 'source tls/' --from "$source_dir"
fixture
touch "$new_dir/.env"
expect_failure 'new release already has .env' --from "$source_dir"
[[ ! -s "$ADOPT_RECORD" ]] || fail 'validation reached docker'
fixture
touch "$new_dir/backups/existing"
expect_failure 'new backups/ must be absent or empty' --from "$source_dir"
fixture
rm "$RUN_DIR/release/release-manifest.json"
expect_failure 'new release manifest is missing' --from "$source_dir"
for lock in .chronicle-restore.lock .chronicle-upgrade.lock .chronicle-secret-rotation; do
  fixture
  mkdir "$source_dir/$lock"
  expect_failure 'incomplete operation preserved' --from "$source_dir"
  [[ ! -s "$ADOPT_RECORD" ]] || fail "$lock reached docker"
done
echo 'PASS: arguments, release source, missing/private env, state directories, and existing destination refused'

for failure in health missing-postgres stop writers-running dump empty-dump down; do
  fixture
  export ADOPT_FAILURE=$failure
  expect_failure 'adopt failed' --from "$source_dir"
  [[ ! -e "$new_dir/.env" && ! -e "$new_dir/upgrade-receipts" ]] || fail "$failure left copied files"
  [[ -f "$source_dir/.env" && -f "$source_dir/tls/cert.pem" && -f "$source_dir/backups/existing.sql" ]] \
    || fail "$failure changed source files"
  python3 - "$ADOPT_RECORD" "$failure" "$source_dir" "$new_dir" <<'PY'
import json
from pathlib import Path
import sys
rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
failure, source, new = sys.argv[2:]
restarts = [row for row in rows if "up" in row]
assert bool(restarts) == (failure not in {"health", "missing-postgres"}), rows
assert all(row[0] == source and "--env-file" in row and "--wait" in row for row in restarts), rows
assert not any(row[1] == "chronicle" for row in rows), rows
assert not list((Path(new) / "backups").iterdir())
assert not list((Path(new) / "tls").iterdir())
PY
done
echo 'PASS: pre-up failures restart the source and remove copied state; unhealthy PostgreSQL never stops writers'

for failure in '' up verify; do
  fixture
  export ADOPT_FAILURE=$failure
  if [[ -n "$failure" ]]; then
    expect_failure 'Restore ' --from "$source_dir"
  else
    # Exported Compose/image overrides must not change the selected project or image pins.
    COMPOSE_PROJECT_NAME=wrong-project BACKEND_IMAGE=wrong-image \
      bash "$new_dir/operator" adopt --from "$source_dir" >"$RUN_DIR/output" 2>&1 \
      || { cat "$RUN_DIR/output" >&2; fail 'happy path failed'; }
  fi
  python3 - "$ADOPT_RECORD" "$source_dir" "$new_dir" "$failure" <<'PY'
import gzip
import hashlib
import json
from pathlib import Path
import stat
import sys
record, source, new, failure = sys.argv[1:]
source, new = Path(source), Path(new)
rows = [json.loads(line) for line in Path(record).read_text().splitlines()]
stop = next(i for i, row in enumerate(rows) if "stop" in row)
dump = next(i for i, row in enumerate(rows) if "pg_dump" in " ".join(row))
down = next(i for i, row in enumerate(rows) if "down" in row)
up = next(i for i, row in enumerate(rows) if row[1:] == ["chronicle", "up"])
assert stop < dump < down < up
assert rows[stop][-4:] == ["backend", "web", "db-init", "db-backup"]
assert all("--project-name" not in row or row[row.index("--project-name") + 1] == "pilot-project" for row in rows)
assert not any("down" in row and ("-v" in row or "--volumes" in row) for row in rows)
copies = [row for row in rows if row[1] == "run"]
assert len(copies) == 2 and all(row[row.index("--user") + 1] == "0:0" for row in copies), rows
assert all(row[-4] == "registry/postgres:fixture" and ":/from:ro" in " ".join(row) for row in copies), rows
assert all(":source" not in " ".join(row) for row in copies), rows
assert [row[-1] for row in rows if row[1] == "chronicle"] == (["up"] if failure == "up" else ["up", "verify"])
assert all(row[0] == str(new) for row in rows if row[1] == "chronicle")
assert not any("up" in row and row[1] == "compose" for row in rows)
env = (new / ".env").read_text()
assert "COMPOSE_PROJECT_NAME=pilot-project\n" in env
assert "OPERATOR_CUSTOM='keep me'" in env and "NEW_DEFAULT=enabled" in env
assert "POSTGRES_PASSWORD='fixture-only-password'" in env
assert ":source" not in env and env.count("@sha256:") == 3
assert stat.S_IMODE((new / ".env").stat().st_mode) == 0o600
assert (source / ".env").read_text().count(":source") == 3
receipt_path, = (new / "upgrade-receipts").glob("*-adopt.json")
receipt = json.loads(receipt_path.read_text())
assert receipt["status"] == ("failed" if failure else "succeeded")
backup = Path(receipt["pre_adopt_backup"]["path"])
assert backup.parent == source / "backups"
assert hashlib.sha256(backup.read_bytes()).hexdigest() == receipt["pre_adopt_backup"]["sha256"]
assert b"SELECT 1" in gzip.decompress(backup.read_bytes())
assert (new / "backups" / backup.name).read_bytes() == backup.read_bytes()
assert (new / "tls/cert.pem").read_bytes() == (source / "tls/cert.pem").read_bytes()
for path in [backup, receipt_path, new / "tls/cert.pem"]:
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
assert not (new / "backups").is_symlink() and not (new / "tls").is_symlink()
PY
done
echo 'PASS: stop/dump/copy/handoff order, pins, project, verified receipt, and post-up recovery boundary'

fixture
sed -i '/^COMPOSE_PROJECT_NAME=/d' "$source_dir/.env"
bash "$new_dir/operator" adopt --from "$source_dir" >"$RUN_DIR/output" 2>&1 \
  || { cat "$RUN_DIR/output" >&2; fail 'default project adoption failed'; }
grep -Fxq 'COMPOSE_PROJECT_NAME=chronicle-selfhost' "$new_dir/.env" || fail 'default project not persisted'
python3 - "$ADOPT_RECORD" <<'PY'
import json
from pathlib import Path
import sys
rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert all(row[row.index("--project-name") + 1] == "chronicle-selfhost"
           for row in rows if "--project-name" in row)
PY
echo 'PASS: absent COMPOSE_PROJECT_NAME uses and persists chronicle-selfhost'
echo 'PASS: selfhost-adopt-command'
