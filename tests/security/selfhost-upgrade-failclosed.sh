#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
UPGRADE_SCRIPT="${ROOT_DIR}/selfhost/upgrade.sh"
RUN_PARENT="${SELFHOST_UPGRADE_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-upgrade}"

fail() {
  echo "self-host upgrade fail-closed test failed: $*" >&2
  exit 1
}

[[ "$RUN_PARENT" == /* ]] || fail "test run parent must be absolute"
case "$RUN_PARENT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
    fail "test run parent must not use a system temporary directory"
    ;;
esac
[[ -x "$UPGRADE_SCRIPT" ]] || fail "upgrade command is missing or not executable"

umask 077
/bin/mkdir -p "$RUN_PARENT"
RUN_DIR="$(/usr/bin/mktemp -d "${RUN_PARENT}/run.XXXXXX")"
/bin/chmod 0700 "$RUN_DIR"
trap '/bin/rm -rf -- "$RUN_DIR"' EXIT
COMMAND_DIR="${RUN_DIR}/commands"
/bin/mkdir "$COMMAND_DIR"

cat >"${COMMAND_DIR}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log="${SELFHOST_UPGRADE_TEST_LOG:?}"
case_name="${SELFHOST_UPGRADE_TEST_CASE:?}"

if [[ "${1:-}" == compose && "${2:-}" == version ]]; then
  printf 'Docker Compose fixture\n'
  exit 0
fi

if [[ "${1:-}" == compose ]]; then
  for variable in COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME BACKEND_IMAGE CHRONICLE_SERVER_ARGS; do
    if [[ -n "${!variable+x}" ]]; then
      printf 'poison:%s\n' "$variable" >>"$log"
      exit 90
    fi
  done

  shift
  env_file=""
  project=""
  compose_count=0
  while (($#)); do
    case "$1" in
      --env-file) env_file="$2"; shift 2 ;;
      --project-name) project="$2"; shift 2 ;;
      -f) compose_count=$((compose_count + 1)); shift 2 ;;
      *) break ;;
    esac
  done
  [[ -n "$env_file" && -n "$project" && "$compose_count" -eq 3 ]] || exit 91
  release=unknown
  case "$env_file" in
    */old/selfhost/.env) release=old ;;
    */new/selfhost/.env) release=new ;;
    *) exit 92 ;;
  esac

  command_name="${1:-}"
  shift || true
  case "$command_name" in
    ps)
      if [[ " $* " == *' -q postgres '* ]]; then
        printf '%s\n' old-postgres
      elif [[ " $* " == *' --status running --services '* ]]; then
        printf '%s\n' postgres
      else
        exit 93
      fi
      ;;
    config)
      if [[ " ${*} " == *' --services '* ]]; then
        if [[ "$release" == new && "$case_name" == service-discovery-failure ]]; then
          printf '%s\n' postgres
          exit 53
        fi
        printf '%s\n' config-guard cert-init db-init restore postgres backend frontend web db-backup ca-export
      elif [[ " ${*} " == *' --format json '* ]]; then
        printf '%s\n' '{"services":{"postgres":{"image":"postgres-fixture@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}'
      fi
      ;;
    pull) printf '%s:pull\n' "$release" >>"$log" ;;
    run)
      if [[ " $* " == *' ca-export '* ]]; then
        printf '%s:ca-export\n' "$release" >>"$log"
      else
        printf '%s:config-guard\n' "$release" >>"$log"
      fi
      ;;
    stop) printf '%s:stop\n' "$release" >>"$log" ;;
    exec)
      printf '%s:dump\n' "$release" >>"$log"
      [[ "$release" == old ]] || exit 94
      [[ "$case_name" != backup-failure ]] || exit 51
      printf 'SELECT 1;\n'
      ;;
    up) printf '%s:up\n' "$release" >>"$log" ;;
    *) exit 95 ;;
  esac
  exit 0
fi

case "${1:-}" in
  inspect)
    printf '%s\n' healthy
    ;;
  exec)
    if [[ "$*" == *server_version_num* ]]; then
      printf '%s\n' 180000
    elif [[ "$*" == *"settings #> '{Encryption,enabled}'"* ]]; then
      [[ "$case_name" != encryption-query-failure ]] || exit 52
      if [[ "$case_name" == encrypted-study ]]; then
        printf '%s\n' blocked
      else
        printf '%s\n' clear
      fi
    elif [[ "$*" == *"to_regclass('public.encrypted_payloads')"* ]]; then
      if [[ "$case_name" == no-encrypted-table ]]; then
        printf '%s\n' absent
      else
        printf '%s\n' present
      fi
    elif [[ "$*" == *'FROM encrypted_payloads'* ]]; then
      if [[ "$case_name" == encrypted-payloads ]]; then
        printf '%s\n' blocked
      else
        printf '%s\n' clear
      fi
    else
      exit 97
    fi
    ;;
  run)
    printf '%s\n' 'postgres (PostgreSQL) 18.4'
    ;;
  *) exit 96 ;;
esac
EOF
/bin/chmod 0755 "${COMMAND_DIR}/docker"

make_case() {
  local case_name="$1"
  local case_dir="${RUN_DIR}/${case_name}"
  local old_bundle="${case_dir}/old"
  local new_bundle="${case_dir}/new"
  /bin/mkdir -p "${old_bundle}/selfhost/backups" "${old_bundle}/selfhost/tls" \
    "${old_bundle}/selfhost/overlays" "${new_bundle}/selfhost/overlays" \
    "${new_bundle}/selfhost/docs"
  /bin/chmod 0700 "${old_bundle}/selfhost/backups" "${old_bundle}/selfhost/tls"

  /bin/cp "$UPGRADE_SCRIPT" "${new_bundle}/selfhost/upgrade.sh"
  /bin/chmod 0755 "${new_bundle}/selfhost/upgrade.sh"
  for bundle in "$old_bundle" "$new_bundle"; do
    cat >"${bundle}/selfhost/chronicle" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == verify ]]
printf 'verify\n' >>"${SELFHOST_UPGRADE_TEST_LOG:?}"
EOF
    /bin/chmod 0755 "${bundle}/selfhost/chronicle"
    printf '# fixture restore\n' >"${bundle}/selfhost/restore.sh"
    /bin/chmod 0755 "${bundle}/selfhost/restore.sh"
    cat >"${bundle}/selfhost/docker-compose.yml" <<'EOF'
services:
  postgres:
    image: ${POSTGRES_IMAGE:?}
  backend:
    image: ${BACKEND_IMAGE:?}
    environment:
      CHRONICLE_SERVER_ARGS: ${CHRONICLE_SERVER_ARGS:-}
EOF
    printf 'services: {}\n' >"${bundle}/selfhost/overlays/mode-behind-proxy-internal.yml"
    printf 'services: {}\n' >"${bundle}/selfhost/overlays/backups.yml"
  done
  printf '# fixture rotation\n' >"${new_bundle}/selfhost/rotate-secret.sh"
  /bin/chmod 0755 "${new_bundle}/selfhost/rotate-secret.sh"
  for document in DEPLOYMENT-COMPATIBILITY.md SECRET-ROTATION.md UNINSTALL-DATA-DELETION.md; do
    printf '# fixture\n' >"${new_bundle}/selfhost/docs/${document}"
  done

  OLD_BUNDLE="$old_bundle" NEW_BUNDLE="$new_bundle" python3 - <<'PY'
from pathlib import Path
import hashlib
import json
import os

old = Path(os.environ["OLD_BUNDLE"])
new = Path(os.environ["NEW_BUNDLE"])
image_values = {
    "BACKEND_IMAGE": "backend-fixture@sha256:" + "b" * 64,
    "SELFHOST_FRONTEND_IMAGE": "frontend-fixture@sha256:" + "c" * 64,
    "CADDY_IMAGE": "caddy-fixture@sha256:" + "d" * 64,
    "POSTGRES_IMAGE": "postgres-fixture@sha256:" + "a" * 64,
}
compose = "docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/backups.yml"

for bundle, version, revision in (
    (old, "1.0.0", "1" * 40),
    (new, "1.0.1", "2" * 40),
):
    env_lines = [
        f"RELEASE_VERSION={version}",
        "COMPOSE_PROJECT_NAME=chronicle-upgrade-fixture",
        f"COMPOSE_FILE={compose}",
        *[f"{key}={value}" for key, value in image_values.items()],
    ]
    (bundle / "selfhost" / ".env.example").write_text("\n".join(env_lines) + "\n")
    files = {}
    for path in sorted(bundle.rglob("*")):
        if path.is_file():
            files[path.relative_to(bundle).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest = {
        "schema_version": 1,
        "release_version": version,
        "source_revision": revision,
        "source_date_epoch": 1700000000,
        "images": {
            "backend": image_values["BACKEND_IMAGE"],
            "frontend": image_values["SELFHOST_FRONTEND_IMAGE"],
            "caddy": image_values["CADDY_IMAGE"],
        },
        "files": files,
    }
    (bundle / "release-manifest.json").write_text(json.dumps(manifest, sort_keys=True) + "\n")

old_env = (old / "selfhost" / ".env.example").read_text()
(old / "selfhost" / ".env").write_text(old_env)
(old / "selfhost" / ".env").chmod(0o600)
PY
  printf '%s\t%s\t%s\n' "$case_dir" "$old_bundle" "$new_bundle"
}

run_upgrade() {
  local case_name="$1" old_bundle="$2" new_bundle="$3" log="$4" output="$5"
  set +e
  PATH="${COMMAND_DIR}:${PATH}" \
    SELFHOST_UPGRADE_TEST_CASE="$case_name" \
    SELFHOST_UPGRADE_TEST_LOG="$log" \
    COMPOSE_FILE="${RUN_DIR}/poison.yml" \
    COMPOSE_PROFILES=restore \
    COMPOSE_PROJECT_NAME=poison-project \
    BACKEND_IMAGE=poison-image:latest \
    CHRONICLE_SERVER_ARGS=poison-arguments \
    /bin/bash "${new_bundle}/selfhost/upgrade.sh" --from "${old_bundle}/selfhost" \
    >"$output" 2>&1
  UPGRADE_STATUS=$?
  set -e
}

assert_order() {
  local log="$1" first="$2" second="$3" third="$4"
  local first_line second_line third_line
  first_line="$(grep -nFx "$first" "$log" | cut -d: -f1)"
  second_line="$(grep -nFx "$second" "$log" | cut -d: -f1)"
  third_line="$(grep -nFx "$third" "$log" | cut -d: -f1)"
  [[ "$first_line" =~ ^[0-9]+$ && "$second_line" =~ ^[0-9]+$ && "$third_line" =~ ^[0-9]+$ &&
      "$first_line" -lt "$second_line" && "$second_line" -lt "$third_line" ]] ||
    fail "event order is not ${first} -> ${second} -> ${third}"
}

IFS=$'\t' read -r success_dir success_old success_new <<<"$(make_case success)"
success_log="${success_dir}/events.log"
run_upgrade success "$success_old" "$success_new" "$success_log" "${success_dir}/output.log"
if [[ "$UPGRADE_STATUS" -ne 0 ]]; then
  /bin/cat "${success_dir}/output.log" >&2
  fail "successful upgrade fixture failed"
fi
assert_order "$success_log" old:stop old:dump new:up
assert_order "$success_log" new:up new:ca-export verify
! grep -q '^poison:' "$success_log" || fail "inherited deployment controls reached Compose"
! grep -Fxq old:up "$success_log" || fail "successful upgrade restarted the old release"
[[ ! -e "${success_old}/selfhost/.chronicle-upgrade.lock" ]] ||
  fail "successful upgrade did not release its operation lock"
python3 - "${success_old}/selfhost/upgrade-receipts" <<'PY'
from pathlib import Path
import json
import sys

receipts = list(Path(sys.argv[1]).glob("*.json"))
if len(receipts) != 1 or json.loads(receipts[0].read_text()).get("status") != "succeeded":
    raise SystemExit("successful upgrade receipt is missing or incorrect")
PY

IFS=$'\t' read -r failure_dir failure_old failure_new <<<"$(make_case backup-failure)"
failure_log="${failure_dir}/events.log"
run_upgrade backup-failure "$failure_old" "$failure_new" "$failure_log" "${failure_dir}/output.log"
[[ "$UPGRADE_STATUS" -ne 0 ]] || fail "upgrade accepted a failed rollback backup"
assert_order "$failure_log" old:stop old:dump old:up
! grep -Fxq new:up "$failure_log" || fail "upgrade started the new release after backup failure"
[[ ! -e "${failure_new}/selfhost/.env" ]] || fail "pre-start failure retained generated new .env"
[[ ! -e "${failure_old}/selfhost/.chronicle-upgrade.lock" ]] ||
  fail "pre-start failure did not release its operation lock"
grep -Fq 'Previous release is healthy again.' "${failure_dir}/output.log" ||
  fail "automatic old-release recovery was not reported"

IFS=$'\t' read -r services_dir services_old services_new <<<"$(make_case service-discovery-failure)"
services_log="${services_dir}/events.log"
run_upgrade service-discovery-failure "$services_old" "$services_new" "$services_log" \
  "${services_dir}/output.log"
[[ "$UPGRADE_STATUS" -ne 0 ]] || fail "upgrade ignored a failed new-release service discovery"
assert_order "$services_log" old:stop old:dump old:up
! grep -Fxq new:up "$services_log" || fail "service-discovery failure started the new release"
[[ ! -e "${services_new}/selfhost/.env" ]] ||
  fail "service-discovery failure retained its generated new environment"
grep -Fq 'could not resolve the new release service graph' "${services_dir}/output.log" ||
  fail "service-discovery failure was not actionable"

IFS=$'\t' read -r inventory_dir inventory_old inventory_new <<<"$(make_case unlisted-file)"
printf 'unlisted fixture\n' >"${inventory_new}/selfhost/unlisted.txt"
inventory_log="${inventory_dir}/events.log"
run_upgrade unlisted-file "$inventory_old" "$inventory_new" "$inventory_log" "${inventory_dir}/output.log"
[[ "$UPGRADE_STATUS" -ne 0 ]] || fail "upgrade accepted an unlisted new-release file"
grep -Fq 'new release file inventory is not exact' "${inventory_dir}/output.log" ||
  fail "unlisted release-file rejection was not comprehensible"
[[ ! -s "$inventory_log" ]] || fail "release inventory failure reached Docker state inspection"

for blocked_case in encrypted-study encrypted-payloads encryption-query-failure; do
  IFS=$'\t' read -r blocked_dir blocked_old blocked_new <<<"$(make_case "$blocked_case")"
  blocked_log="${blocked_dir}/events.log"
  run_upgrade "$blocked_case" "$blocked_old" "$blocked_new" "$blocked_log" \
    "${blocked_dir}/output.log"
  [[ "$UPGRADE_STATUS" -ne 0 ]] || fail "upgrade accepted unsupported encrypted state: $blocked_case"
  [[ ! -s "$blocked_log" ]] || fail "encrypted-state preflight mutated Compose services: $blocked_case"
  [[ ! -e "${blocked_new}/selfhost/.env" ]] ||
    fail "encrypted-state preflight rendered a new environment: $blocked_case"
  [[ ! -e "${blocked_old}/selfhost/.chronicle-upgrade.lock" ]] ||
    fail "encrypted-state preflight did not release its operation lock: $blocked_case"
done

grep -Fq 'cannot safely export study-encrypted collection data' \
  "${RUN_DIR}/encrypted-study/output.log" ||
  fail "enabled study-encryption rejection was not actionable"
grep -Fq 'do not delete ciphertext' "${RUN_DIR}/encrypted-payloads/output.log" ||
  fail "historical ciphertext rejection did not preserve data"
grep -Fq 'could not evaluate the study-encryption upgrade precondition' \
  "${RUN_DIR}/encryption-query-failure/output.log" ||
  fail "indeterminate encryption preflight did not fail closed"

IFS=$'\t' read -r no_table_dir no_table_old no_table_new <<<"$(make_case no-encrypted-table)"
no_table_log="${no_table_dir}/events.log"
run_upgrade no-encrypted-table "$no_table_old" "$no_table_new" "$no_table_log" \
  "${no_table_dir}/output.log"
[[ "$UPGRADE_STATUS" -eq 0 ]] || fail "upgrade rejected a valid database without encrypted_payloads"
assert_order "$no_table_log" old:stop old:dump new:up

echo "self-host upgrade fail-closed test passed"
