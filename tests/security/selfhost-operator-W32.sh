#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
WORK_DIR=/home/opt/chronicle_work/launch-audit-1003/sol/webselfhost-logs
RUN_DIR="$(mktemp -d "${WORK_DIR}/W32.XXXXXX")"
trap 'rm -rf -- "$RUN_DIR"' EXIT
PASSWORD='synthetic-dashboard-password-W32'

fail() { echo "FAIL W32: $*" >&2; exit 1; }

make_fixture() {
  local case_dir="$1"
  mkdir -p "${case_dir}/selfhost" "${case_dir}/bin"
  cp "${ROOT_DIR}/selfhost/chronicle" "${ROOT_DIR}/selfhost/guard-config.sh" \
    "${ROOT_DIR}/selfhost/network-policy.sh" "${ROOT_DIR}/selfhost/.env.example" \
    "${case_dir}/selfhost/"
  chmod 0755 "${case_dir}/selfhost/chronicle"
  cat >"${case_dir}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == 'compose ls --all --format json' ]]; then
  printf '[]\n'
  exit 0
fi
if [[ "${1:-}" == run ]]; then
  cat >/dev/null
  printf '%s\n' '$2a$14$syntheticbcryptvalueabcdefghijklmnopqrstuv0123456789ABCDE'
fi
exit 0
SH
  cat >"${case_dir}/bin/openssl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'rand -base64 32' ]] || exit 91
printf '%s\n' 'synthetic-generated-value-for-operator-test-only'
SH
  cat >"${case_dir}/bin/ip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-4 -o addr show' ]] || exit 92
printf '%s\n' '1: lo inet 127.0.0.1/8 scope host lo'
SH
  cat >"${case_dir}/bin/ss" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-lnt' ]] || exit 93
printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port'
SH
  chmod 0755 "${case_dir}/bin/"*
}

run_setup() {
  local case_dir="$1" project="$2" input="$3" output="$4" status
  if (
    cd "${case_dir}/selfhost"
    printf '%s' "$input" | env \
      "PATH=${case_dir}/bin:${PATH}" \
      "COMPOSE_PROJECT_NAME=${project}" \
      bash ./chronicle setup
  ) >"$output" 2>&1; then
    return 0
  else
    status=$?
  fi
  return "$status"
}

invalid_dir="${RUN_DIR}/invalid-project"
make_fixture "$invalid_dir"
printf '%s\n' 'COMPOSE_PROJECT_NAME=Previous_invalid_name' 'CHRONICLE_STATE_DIR=.' \
  >"${invalid_dir}/selfhost/.env"
chmod 0600 "${invalid_dir}/selfhost/.env"
cp "${invalid_dir}/selfhost/.env" "${RUN_DIR}/env-before-invalid-setup"
invalid_input=$(printf 'y\n1\nchronicle.study-host.org\n\n\n%s\n%s\n\nn\n' "$PASSWORD" "$PASSWORD")
if run_setup "$invalid_dir" 'Bad-Name' "$invalid_input" "${RUN_DIR}/invalid-output.log"; then
  fail 'setup accepted an invalid inherited Compose project name'
fi
grep -Fq 'deployment name must be lowercase letters, digits, dashes or underscores' \
  "${RUN_DIR}/invalid-output.log" || fail 'invalid project failure did not explain the Compose naming rule'
cmp -s "${invalid_dir}/selfhost/.env" "${RUN_DIR}/env-before-invalid-setup" ||
  fail 'invalid project name changed the prior .env configuration'

valid_dir="${RUN_DIR}/valid-project"
make_fixture "$valid_dir"
valid_input=$(printf '1\nchronicle.study-host.org\n\n\n%s\n%s\n\nn\n' "$PASSWORD" "$PASSWORD")
if ! run_setup "$valid_dir" 'pilot-study_2' "$valid_input" "${RUN_DIR}/valid-output.log"; then
  cat "${RUN_DIR}/valid-output.log" >&2
  fail 'setup rejected a valid constrained Compose project name'
fi
grep -Fqx 'COMPOSE_PROJECT_NAME=pilot-study_2' "${valid_dir}/selfhost/.env" ||
  fail 'setup did not preserve the accepted project name in generated configuration'
echo 'PASS W32: invalid project names fail before .env replacement; valid constrained name is retained'
