#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
WORK_DIR=/home/opt/chronicle_work/launch-audit-1003/sol/webselfhost-logs
RUN_DIR="$(mktemp -d "${WORK_DIR}/W80.XXXXXX")"
trap 'rm -rf -- "$RUN_DIR"' EXIT
FIXTURE="${RUN_DIR}/selfhost"
BIN="${RUN_DIR}/bin"
PASSWORD='synthetic-dashboard-password-W80'
GENERATED='synthetic-generated-value-for-W80-only'
HASH='$2a$14$syntheticbcryptvalueabcdefghijklmnopqrstuv0123456789ABCDE'

fail() { echo "FAIL W80: $*" >&2; exit 1; }

mkdir -p "$FIXTURE" "$BIN"
cp "${ROOT_DIR}/selfhost/chronicle" "${ROOT_DIR}/selfhost/guard-config.sh" \
  "${ROOT_DIR}/selfhost/network-policy.sh" "${ROOT_DIR}/selfhost/.env.example" "$FIXTURE/"
chmod 0755 "${FIXTURE}/chronicle"

cat >"${BIN}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == 'compose ls --all --format json' ]]; then
  printf '[]\n'
elif [[ "${1:-}" == run ]]; then
  cat >/dev/null
  printf '%s\n' "$W80_HASH"
fi
exit 0
SH
cat >"${BIN}/openssl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'rand -base64 32' ]] || exit 91
printf '%s\n' "$W80_GENERATED"
SH
cat >"${BIN}/ip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-4 -o addr show' ]] || exit 92
printf '%s\n' '1: lo inet 127.0.0.1/8 scope host lo'
SH
cat >"${BIN}/ss" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-lnt' ]] || exit 93
printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port'
SH
chmod 0755 "${BIN}/"*

run_setup() {
  local output="$1" overwrite="$2"
  local -a answers=()
  if [[ "$overwrite" == true ]]; then
    answers+=(y 1 chronicle.study-host.org '' '' '' n)
  else
    answers+=(1 chronicle.study-host.org '' '' "$PASSWORD" "$PASSWORD" '' n)
  fi
  (
    cd "$FIXTURE"
    printf '%s\n' "${answers[@]}" | env \
      "PATH=${BIN}:${PATH}" \
      "COMPOSE_PROJECT_NAME=pilot-study" \
      "W80_GENERATED=${GENERATED}" \
      "W80_HASH=${HASH}" \
      bash ./chronicle setup
  ) >"$output" 2>&1
}

run_setup "${RUN_DIR}/first-setup.log" false || {
  cat "${RUN_DIR}/first-setup.log" >&2
  fail 'initial synthetic setup failed'
}
grep -Fq 'secrets generated, mode 600' "${RUN_DIR}/first-setup.log" ||
  fail 'initial setup did not report generated credentials'
[[ -s "${FIXTURE}/.env" ]] || fail 'initial setup did not create .env'
chmod 0600 "${FIXTURE}/.env"

run_setup "${RUN_DIR}/rerun.log" true || {
  cat "${RUN_DIR}/rerun.log" >&2
  fail 'synthetic setup rerun failed'
}
grep -Fq 'existing secrets preserved, no credentials generated, mode 600' "${RUN_DIR}/rerun.log" ||
  fail 'rerun did not report that existing credentials were retained'
if grep -Fq 'secrets generated, mode 600' "${RUN_DIR}/rerun.log"; then
  fail 'rerun still claimed that credentials were generated'
fi
for value in "$PASSWORD" "$GENERATED" "$HASH"; do
  if grep -Fq "$value" "${RUN_DIR}/first-setup.log" "${RUN_DIR}/rerun.log"; then
    fail 'setup output printed credential material'
  fi
done
echo 'PASS W80: first setup reports generated credentials; rerun reports preserved credentials without printing values'
