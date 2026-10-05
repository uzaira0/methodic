#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
WORK_DIR=/home/opt/chronicle_work/launch-audit-1003/sol/webselfhost-logs
RUN_DIR="$(mktemp -d "${WORK_DIR}/W28.XXXXXX")"
trap 'rm -rf -- "$RUN_DIR"' EXIT
CHRONICLE_SCRIPT="${ROOT_DIR}/selfhost/chronicle"
ROTATE_SCRIPT="${ROOT_DIR}/selfhost/rotate-secret.sh"
COMMANDS=(setup up check verify status doctor monitoring logs down restore deletion-status upgrade update adopt rotate-secret)

fail() {
  echo "self-host CLI argument regression failed: $*" >&2
  exit 1
}

make_fixture() {
  local case_dir="$1"
  mkdir -p "${case_dir}/selfhost" "${case_dir}/bin"
  cp "$CHRONICLE_SCRIPT" "${case_dir}/selfhost/chronicle"
  cp "$ROTATE_SCRIPT" "${case_dir}/selfhost/rotate-secret.sh"
  chmod 0755 "${case_dir}/selfhost/chronicle" "${case_dir}/selfhost/rotate-secret.sh"
  cat >"${case_dir}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CLI_TEST_DOCKER_LOG"
SH
  chmod 0755 "${case_dir}/bin/docker"
}

run_without_config() {
  local action="$1" command="$2" expected="$3" case_dir="${RUN_DIR}/${1}-${2}" status
  make_fixture "$case_dir"
  if (
    cd "${case_dir}/selfhost"
    env \
      "PATH=${case_dir}/bin:${PATH}" \
      "CLI_TEST_DOCKER_LOG=${case_dir}/docker.log" \
      ./chronicle "$command" "$action"
  ) >"${case_dir}/output.log" 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ "$status" == "$expected" ]] || {
    cat "${case_dir}/output.log" >&2
    fail "$command $action exited $status, expected $expected"
  }
  [[ ! -s "${case_dir}/docker.log" ]] || fail "$command $action reached Docker before validation"
  [[ ! -e "${case_dir}/selfhost/.env" ]] || fail "$command $action wrote configuration"
  [[ ! -e "${case_dir}/selfhost/operator-receipts" ]] ||
    fail "$command $action recorded an operation before validation"
  if [[ "$action" == --help ]]; then
    grep -Fq "./chronicle ${command}" "${case_dir}/output.log" ||
      fail "$command help omitted its command usage"
  fi
}

for command in "${COMMANDS[@]}"; do
  run_without_config --help "$command" 0
done

help_dir="${RUN_DIR}/help-usage"
make_fixture "$help_dir"
(
  cd "${help_dir}/selfhost"
  env "PATH=${help_dir}/bin:${PATH}" "CLI_TEST_DOCKER_LOG=${help_dir}/docker.log" ./chronicle --help
) >"${help_dir}/top-level.log" 2>&1 || fail 'top-level help did not succeed'
grep -Fq './chronicle restore [--yes] [--no-start] --trusted-sha256=SHA256' \
  "${help_dir}/top-level.log" || fail 'top-level usage omitted the independently trusted restore digest'
for command in restore upgrade rotate-secret; do
  (
    cd "${help_dir}/selfhost"
    env "PATH=${help_dir}/bin:${PATH}" "CLI_TEST_DOCKER_LOG=${help_dir}/docker.log" \
      ./chronicle "$command" --help
  ) >"${help_dir}/${command}.log" 2>&1 || fail "$command help did not succeed"
done
grep -Fq 'usage: ./chronicle restore [--yes] [--no-start] --trusted-sha256=SHA256' \
  "${help_dir}/restore.log" || fail 'restore help omitted the required trusted digest'
grep -Fq 'usage: ./chronicle upgrade --from DIR' "${help_dir}/upgrade.log" ||
  fail 'upgrade help omitted its --from argument'
grep -Fq 'usage: ./chronicle rotate-secret' "${help_dir}/rotate-secret.log" ||
  fail 'rotate-secret help omitted its supported command form'
[[ ! -s "${help_dir}/docker.log" ]] || fail 'help invoked Docker'
[[ ! -e "${help_dir}/selfhost/.env" ]] || fail 'help required or wrote .env'

for command in "${COMMANDS[@]}"; do
  run_without_config --audit-invalid "$command" 2
done

log_dir="${RUN_DIR}/forwarded-logs"
make_fixture "$log_dir"
cat >"${log_dir}/selfhost/.env" <<'EOF'
COMPOSE_PROJECT_NAME=chronicle-operator-w28
CHRONICLE_STATE_DIR=.
MOBILE_SIGNING_ENABLED=false
MOBILE_SIGNING_REQUIRED=false
MOBILE_SIGNING_SECRET=
MOBILE_SIGNING_SECRET_PREVIOUS=
EOF
chmod 0600 "${log_dir}/selfhost/.env"
(
  cd "${log_dir}/selfhost"
  env \
    "PATH=${log_dir}/bin:${PATH}" \
    "CLI_TEST_DOCKER_LOG=${log_dir}/docker.log" \
    ./chronicle logs backend
) >"${log_dir}/output.log" 2>&1 || {
  cat "${log_dir}/output.log" >&2
  fail 'valid logs service argument did not reach the Compose command'
}
grep -Fxq 'compose -p chronicle-operator-w28 logs -f --tail=100 backend' \
  "${log_dir}/docker.log" || fail 'logs discarded its selected service argument'
echo 'PASS: command help and invalid-option matrix run before configuration or Docker; valid args forward'
