#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RUN_PARENT="${SELFHOST_SETUP_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-setup-secrets}"
REAL_PYTHON="$(command -v python3)"

fail() {
  echo "self-host setup secret-custody test failed: $*" >&2
  exit 1
}

[[ "$RUN_PARENT" == /* ]] || fail "test run parent must be absolute"
case "$RUN_PARENT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
    fail "test run parent must not use a system temporary directory"
    ;;
esac

umask 077
/bin/mkdir -p "$RUN_PARENT"
RUN_DIR="$(/usr/bin/mktemp -d "${RUN_PARENT}/run.XXXXXX")"
/bin/chmod 0700 "$RUN_DIR"
trap '/bin/rm -rf -- "$RUN_DIR"' EXIT

FIXTURE_SELFHOST="${RUN_DIR}/selfhost"
COMMAND_DIR="${RUN_DIR}/commands"
/bin/mkdir -p "$FIXTURE_SELFHOST" "$COMMAND_DIR"
/bin/cp "${ROOT_DIR}/selfhost/chronicle" "${ROOT_DIR}/selfhost/.env.example" "$FIXTURE_SELFHOST/"
/bin/chmod 0755 "${FIXTURE_SELFHOST}/chronicle"

PASSWORD='fixture-dashboard-password-never-print-9472'
GENERATED='fixture-generated-secret-value-abcdefghijklmnopqrstuvwxyz0123456789'
DOCKER_ARGS="${RUN_DIR}/docker-args.txt"
PYTHON_ARGS="${RUN_DIR}/python-args.txt"

cat >"${COMMAND_DIR}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == compose && "$*" == *' ls '* ]]; then
  printf '[]\n'
  exit 0
fi
for argument in "$@"; do
  [[ "$argument" != *"${SELFHOST_SETUP_TEST_PASSWORD}"* ]] || {
    echo "dashboard password reached Docker argv" >&2
    exit 91
  }
done
printf '%s\n' "$@" >"${SELFHOST_SETUP_TEST_DOCKER_ARGS}"
plaintext="$(cat)"
[[ "$plaintext" == "${SELFHOST_SETUP_TEST_PASSWORD}" ]] || {
  echo "dashboard password was not delivered to Caddy over stdin" >&2
  exit 92
}
printf '%s\n' '$2a$14$fixturebcryptvalueabcdefghijklmnopqrstuv0123456789ABCDE'
EOF

cat >"${COMMAND_DIR}/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "rand -base64 32" ]] || exit 93
printf '%s\n' "${SELFHOST_SETUP_TEST_GENERATED}"
EOF

cat >"${COMMAND_DIR}/ss" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "-lnt" ]] || exit 96
cat <<'SOCKETS'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port
LISTEN 0      128    127.0.0.1:8080   0.0.0.0:*
LISTEN 0      128    127.0.0.1:8081   0.0.0.0:*
LISTEN 0      128    0.0.0.0:443      0.0.0.0:*
LISTEN 0      128    0.0.0.0:80       0.0.0.0:*
SOCKETS
EOF

cat >"${COMMAND_DIR}/ifconfig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<'ADDRESSES'
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
        inet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        inet 192.168.50.10 netmask 0xffffff00 broadcast 192.168.50.255
ADDRESSES
EOF

cat >"${COMMAND_DIR}/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-4 -o addr show' ]] || exit 97
printf '%s\n' \
  '1: lo    inet 127.0.0.1/8 scope host lo' \
  '2: en0   inet 192.168.50.10/24 brd 192.168.50.255 scope global en0'
EOF

cat >"${COMMAND_DIR}/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  [[ "$argument" != *"${SELFHOST_SETUP_TEST_PASSWORD}"* ]] || {
    echo "dashboard password reached Python argv" >&2
    exit 94
  }
  [[ "$argument" != *"${SELFHOST_SETUP_TEST_GENERATED}"* ]] || {
    echo "generated deployment secret reached Python argv" >&2
    exit 95
  }
done
printf '%s\n' "$@" >"${SELFHOST_SETUP_TEST_PYTHON_ARGS}"
exec "${SELFHOST_SETUP_TEST_REAL_PYTHON}" "$@"
EOF
/bin/chmod 0755 \
  "${COMMAND_DIR}/docker" \
  "${COMMAND_DIR}/ifconfig" \
  "${COMMAND_DIR}/ip" \
  "${COMMAND_DIR}/openssl" \
  "${COMMAND_DIR}/python3" \
  "${COMMAND_DIR}/ss"

OUTPUT="${RUN_DIR}/setup-output.txt"
if ! (
  # Deliberately remove the caller's protection. The operator script itself must set its
  # private umask before the first generated secret or sibling publication file is created.
  umask 000
  {
    printf '1\n'                         # behind an institutional proxy
    printf 'chronicle.example.test\n'    # hostname
    printf '\n'                          # loopback proxy bind
    printf '\n'                          # loopback dashboard bind
    printf '%s\n' "$PASSWORD"
    printf '%s\n' "$PASSWORD"
    printf '\n'                          # public per-device-key flow; no legacy shared HMAC
    printf 'n\n'                         # monitoring off for the focused fixture
  } | PATH="${COMMAND_DIR}:${PATH}" \
      SELFHOST_SETUP_TEST_PASSWORD="$PASSWORD" \
      SELFHOST_SETUP_TEST_GENERATED="$GENERATED" \
      SELFHOST_SETUP_TEST_DOCKER_ARGS="$DOCKER_ARGS" \
      SELFHOST_SETUP_TEST_PYTHON_ARGS="$PYTHON_ARGS" \
      SELFHOST_SETUP_TEST_REAL_PYTHON="$REAL_PYTHON" \
      /bin/bash "${FIXTURE_SELFHOST}/chronicle" setup >"$OUTPUT" 2>&1
); then
  fail "interactive setup fixture failed"
fi

[[ -s "${FIXTURE_SELFHOST}/.env" ]] || fail "setup did not create .env"
mode="$(stat -c '%a' "${FIXTURE_SELFHOST}/.env" 2>/dev/null || stat -f '%Lp' "${FIXTURE_SELFHOST}/.env")"
[[ "$mode" == 600 ]] || fail "generated .env mode is ${mode}, expected 600"

! grep -Fq "$PASSWORD" "$OUTPUT" || fail "dashboard password was printed"
! grep -Fq "$GENERATED" "$OUTPUT" || fail "generated deployment secret was printed"
! grep -Fq "$PASSWORD" "$DOCKER_ARGS" || fail "dashboard password reached Docker argv log"
! grep -Fq "$PASSWORD" "$PYTHON_ARGS" || fail "dashboard password reached Python argv log"
! grep -Fq "$GENERATED" "$PYTHON_ARGS" || fail "generated deployment secret reached Python argv log"
! grep -Fqx -- '--plaintext' "$DOCKER_ARGS" || fail "Caddy hash command used a plaintext argv"
grep -Fqx -- '-i' "$DOCKER_ARGS" || fail "Caddy hash container did not read stdin"
grep -Fqx -- '--network' "$DOCKER_ARGS" || fail "Caddy hash container did not disable networking"

python3 - "${FIXTURE_SELFHOST}/.env" <<'PY'
from pathlib import Path
import re
import sys

values = {}
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    match = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
    if match:
        if match.group(1) in values:
            raise SystemExit(f"duplicate generated setting: {match.group(1)}")
        values[match.group(1)] = match.group(2)

for key in (
    "POSTGRES_PASSWORD",
    "JWT_SECRET",
    "METRICS_PASSWORD",
    "CHRONICLE_INTERNAL_WEB_SECRET",
    "GRAFANA_ADMIN_PASSWORD",
):
    value = values.get(key, "")
    if not value or "CHANGE_ME" in value:
        raise SystemExit(f"setup did not generate {key}")
if values.get("MOBILE_SIGNING_ENABLED") != "false":
    raise SystemExit("setup did not default legacy mobile signing off")
if values.get("MOBILE_SIGNING_REQUIRED") != "false":
    raise SystemExit("setup did not default legacy mobile signing enforcement off")
if values.get("MOBILE_SIGNING_SECRET"):
    raise SystemExit("public-client setup generated an unnecessary deployment-wide mobile key")
if values.get("MOBILE_SIGNING_SECRET_PREVIOUS"):
    raise SystemExit("public-client setup retained an unnecessary previous mobile key")
if values.get("HTTP_PORT") != "8082":
    raise SystemExit("setup did not move the occupied public listener to port 8082")
if values.get("INTERNAL_PORT") != "8083":
    raise SystemExit("setup reused the selected public port for the internal listener")
if not values.get("DASHBOARD_PASSWORD_HASH", "").startswith("'$2"):
    raise SystemExit("setup did not store a single-quoted bcrypt hash")
PY

grep -Fq 'Legacy shared-HMAC compatibility is disabled; no deployment-wide mobile key was generated.' "$OUTPUT" \
  || fail "setup did not explain the public per-device-key default"

FIXTURE_LOCAL_SELFHOST="${RUN_DIR}/selfhost-local"
/bin/mkdir -p "$FIXTURE_LOCAL_SELFHOST"
/bin/cp "${ROOT_DIR}/selfhost/chronicle" "${ROOT_DIR}/selfhost/.env.example" "$FIXTURE_LOCAL_SELFHOST/"
/bin/chmod 0755 "${FIXTURE_LOCAL_SELFHOST}/chronicle"
LOCAL_OUTPUT="${RUN_DIR}/setup-local-output.txt"
if ! (
  umask 000
  {
    printf '3\n'                         # local HTTPS trial
    printf '192.168.50.10\n'             # exact address exposed by fake ifconfig
    printf '%s\n' "$PASSWORD"
    printf '%s\n' "$PASSWORD"
    printf '\n'                          # public per-device-key flow
    printf 'n\n'                         # monitoring off
  } | PATH="${COMMAND_DIR}:${PATH}" \
      SELFHOST_SETUP_TEST_PASSWORD="$PASSWORD" \
      SELFHOST_SETUP_TEST_GENERATED="$GENERATED" \
      SELFHOST_SETUP_TEST_DOCKER_ARGS="$DOCKER_ARGS" \
      SELFHOST_SETUP_TEST_PYTHON_ARGS="$PYTHON_ARGS" \
      SELFHOST_SETUP_TEST_REAL_PYTHON="$REAL_PYTHON" \
      /bin/bash "${FIXTURE_LOCAL_SELFHOST}/chronicle" setup >"$LOCAL_OUTPUT" 2>&1
); then
  fail "local HTTPS setup fixture failed"
fi
python3 - "${FIXTURE_LOCAL_SELFHOST}/.env" <<'PY'
from pathlib import Path
import sys

values = dict(
    line.split("=", 1)
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if "=" in line
)
if values.get("LOCAL_HTTPS_PORT") != "444":
    raise SystemExit("local setup did not move occupied HTTPS port 443 to 444")
if values.get("LOCAL_HTTP_PORT") != "81":
    raise SystemExit("local setup did not move occupied CA/redirect port 80 to 81")
if values.get("CHRONICLE_PUBLIC_BASE_URL") != "https://192.168.50.10:444":
    raise SystemExit("local setup did not publish the exact selected HTTPS origin")
if values.get("COMPOSE_FILE") != "docker-compose.yml:overlays/mode-local-https.yml:overlays/backups.yml":
    raise SystemExit("local setup did not select the local HTTPS deployment mode")
PY
grep -Fq 'Trial HTTPS/CA ports 444 and 81 are free; using those.' "$LOCAL_OUTPUT" \
  || fail "local setup did not explain its selected fallback ports"

FIXTURE_LEGACY_SELFHOST="${RUN_DIR}/selfhost-legacy"
/bin/mkdir -p "$FIXTURE_LEGACY_SELFHOST"
/bin/cp "${ROOT_DIR}/selfhost/chronicle" "${ROOT_DIR}/selfhost/.env.example" "$FIXTURE_LEGACY_SELFHOST/"
/bin/chmod 0755 "${FIXTURE_LEGACY_SELFHOST}/chronicle"
LEGACY_OUTPUT="${RUN_DIR}/setup-legacy-output.txt"
if ! (
  umask 000
  {
    printf '1\n'                         # behind an institutional proxy
    printf 'legacy.example.test\n'       # hostname
    printf '\n'                          # loopback proxy bind
    printf '\n'                          # loopback dashboard bind
    printf '%s\n' "$PASSWORD"
    printf '%s\n' "$PASSWORD"
    printf 'y\n'                         # explicit controlled-legacy opt-in
    printf 'n\n'                         # monitoring off for the focused fixture
  } | PATH="${COMMAND_DIR}:${PATH}" \
      SELFHOST_SETUP_TEST_PASSWORD="$PASSWORD" \
      SELFHOST_SETUP_TEST_GENERATED="$GENERATED" \
      SELFHOST_SETUP_TEST_DOCKER_ARGS="$DOCKER_ARGS" \
      SELFHOST_SETUP_TEST_PYTHON_ARGS="$PYTHON_ARGS" \
      SELFHOST_SETUP_TEST_REAL_PYTHON="$REAL_PYTHON" \
      /bin/bash "${FIXTURE_LEGACY_SELFHOST}/chronicle" setup >"$LEGACY_OUTPUT" 2>&1
); then
  fail "explicit legacy compatibility setup fixture failed"
fi

python3 - "${FIXTURE_LEGACY_SELFHOST}/.env" "$GENERATED" <<'PY'
from pathlib import Path
import sys

values = {}
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if "=" in line:
        key, value = line.split("=", 1)
        values[key] = value
if values.get("MOBILE_SIGNING_ENABLED") != "true":
    raise SystemExit("explicit legacy opt-in did not enable mobile HMAC")
if values.get("MOBILE_SIGNING_REQUIRED") != "true":
    raise SystemExit("explicit legacy opt-in did not require mobile HMAC")
if values.get("MOBILE_SIGNING_SECRET") != sys.argv[2]:
    raise SystemExit("explicit legacy opt-in did not generate its protected compatibility key")
if values.get("MOBILE_SIGNING_SECRET_PREVIOUS"):
    raise SystemExit("fresh legacy opt-in unexpectedly created a previous-key overlap")
PY
grep -Fq 'Controlled legacy HMAC compatibility is enabled' "$LEGACY_OUTPUT" \
  || fail "explicit legacy setup did not explain the controlled compatibility boundary"

echo "self-host setup secret-custody test passed"
