#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RESTORE_SCRIPT="${ROOT_DIR}/docker/restore-chronicle.sh"
FIXTURE_COMMANDS="${ROOT_DIR}/tests/security/fixtures/legacy-restore/commands"
MIGRATE_FIXTURE="${ROOT_DIR}/tests/security/fixtures/legacy-restore/migrate-tde.sh"
RUN_PARENT="${LEGACY_RESTORE_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/legacy-restore}"
JQ_BIN="${CHRONICLE_RESTORE_JQ:-$(command -v jq || true)}"

fail() {
  echo "legacy restore fail-closed test failed: $*" >&2
  exit 1
}

assert_marker_state() {
  local marker="$1"
  local expected="$2"
  local description="$3"
  if [[ "$expected" == "true" ]]; then
    [[ -f "$marker" ]] || fail "${description} was not exercised"
  else
    [[ ! -e "$marker" ]] || fail "${description} ran past the expected stop point"
  fi
}

[[ "$RUN_PARENT" == /* ]] || fail "test run parent must be absolute"
case "$RUN_PARENT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
    fail "test run parent must not use a system temporary directory"
    ;;
esac
[[ ! -L "$RUN_PARENT" ]] || fail "test run parent must not be a symlink"

bash -n "$RESTORE_SCRIPT" "$MIGRATE_FIXTURE"
for fixture_command in docker openssl sha256sum sleep tar; do
  [[ -x "${FIXTURE_COMMANDS}/${fixture_command}" ]] ||
    fail "required fixture command is missing or not executable: ${FIXTURE_COMMANDS}/${fixture_command}"
  resolved_command="$(PATH="${FIXTURE_COMMANDS}:/usr/bin:/bin" command -v "$fixture_command")"
  [[ "$resolved_command" == "${FIXTURE_COMMANDS}/${fixture_command}" ]] ||
    fail "fixture command did not resolve exactly: ${fixture_command} -> ${resolved_command}"
done
[[ -x "$MIGRATE_FIXTURE" ]] || fail "required migrate-tde fixture is missing or not executable"
[[ -n "$JQ_BIN" && -x "$JQ_BIN" ]] || fail "jq is required for the structured manifest fixture"

umask 077
/bin/mkdir -p "$RUN_PARENT"
RUN_DIR="$(/usr/bin/mktemp -d "${RUN_PARENT}/run.XXXXXX")"
/bin/chmod 0700 "$RUN_DIR"
export TMPDIR="$RUN_DIR" TMP="$RUN_DIR" TEMP="$RUN_DIR"

cleanup() {
  /bin/rm -rf -- "$RUN_DIR"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

reset_case() {
  CASE_KEYRING_TAR_EXIT=0
  CASE_KEYRING_MATERIAL=present
  CASE_CONFIG_TAR_EXIT=0
  CASE_CONFIG_SHAPE=valid
  CASE_DEPLOYMENT_TAR_EXIT=0
  CASE_DEPLOYMENT_MANIFEST_VALID=true
  CASE_AUDIT_TAR_EXIT=0
  CASE_AUDIT_REQUIRED=false
  CASE_AUDIT_IMAGE_EXIT=0
  CASE_AUDIT_PREFLIGHT_EXIT=0
  CASE_AUDIT_VOLUME_EXIT=0
  CASE_AUDIT_RESTORE_EXIT=0
  CASE_COMPOSE_DOWN_EXIT=0
  CASE_CONTAINER_STATE_EXIT=0
  CASE_ARCHIVE_LIST_EXIT=0
  CASE_PG_RESTORE_EXIT=0
  CASE_CREATE_DATABASE_EXIT=0
  CASE_KEYRING_RESTORE_EXIT=0
  CASE_TABLE_QUERY_EXIT=0
  CASE_TABLE_COUNT=7
  CASE_SCHEMA_ANCHOR_COUNT=5
  CASE_FLYWAY_MAX=82
  CASE_FLYWAY_BASELINE=54
  CASE_FLYWAY_SUCCESSFUL=29
  CASE_FLYWAY_FAILED=0
  CASE_FLYWAY_INVALID=0
  CASE_FLYWAY_HISTORY_ROW='[1,"54","baseline","BASELINE","baseline",null,true]'
  CASE_FLYWAY_HISTORY_EXIT=0
  CASE_POST_DOWN_BACKEND_RUNNING=false
  CASE_MIGRATION_PREFLIGHT_EXIT=0
  CASE_MIGRATION_RUN_EXIT=0
  CASE_POST_MIGRATION_FLYWAY_MAX=82
  CASE_POST_MIGRATION_FLYWAY_FAILED=0
  CASE_TDE_PROVIDER="file"
  CASE_TDE_PROVIDER_NAME=chronicle-file-vault
  CASE_TDE_PROVIDER_TYPE="file"
  CASE_TDE_KEY_NAME=chronicle-principal-key
  CASE_TDE_VERIFY_EXIT=0
  CASE_CURRENT_TABLE_COUNT=7
  CASE_CURRENT_TDE_COUNT=7
  CASE_CURRENT_PLAIN_COUNT=0
  CASE_DATA_READ_EXIT=0
  CASE_FULL_START_EXIT=0
  CASE_POSTGRES_FINAL_HEALTH_EXIT=0
  CASE_BACKEND_HEALTH=healthy
  CASE_FRONTEND_HEALTH=healthy
  CASE_PREPROCESSING_HEALTH=healthy
  CASE_HEALTH_FAILURE_CONTAINER=""
  CASE_FINAL_TABLE_COUNT=7
  CASE_FINAL_TDE_COUNT=7
  CASE_FINAL_PLAIN_COUNT=0
  CASE_MIGRATE_TDE_EXIT=0
  CASE_QUIESCE_EXIT=0
  CASE_DIRECT_STOP_EXIT=0
  CASE_PRIMARY_STREAMS=1
  CASE_PRIMARY_REPLICATION_QUERY_EXIT=0
  CASE_REPLICA_RECOVERY_STATE=t
  CASE_REPLICA_QUERY_EXIT=0
  CASE_RESTORE_CONFIG=false
  CASE_MANIFEST_MUTATION=none
  CASE_ALLOW_LEGACY_V1=false
  CASE_LEGACY_PROVIDER="file"
  CASE_LEGACY_KEY_NAME=chronicle-principal-key

  EXPECT_RESULT=success
  EXPECT_PREFLIGHT=true
  EXPECT_LIST=true
  EXPECT_TERMINATE=true
  EXPECT_DROP=true
  EXPECT_CREATE=true
  EXPECT_RESTORE=true
  EXPECT_KEYRING_RESTORE=true
  EXPECT_KEYRING_CLEANUP=false
  EXPECT_MIGRATION_RUN=true
  EXPECT_MIGRATE=true
  EXPECT_FULL_START=true
  EXPECT_QUIESCE=false
  EXPECT_AUDIT_IMAGE=false
  EXPECT_AUDIT_PREFLIGHT=false
  EXPECT_AUDIT_VOLUME=false
  EXPECT_AUDIT_RESTORE=false
  EXPECT_MESSAGE="Database restored (7 tables)"
}

run_case() {
  local case_name="$1"
  local case_dir="${RUN_DIR}/${case_name}"
  local script_dir="${case_dir}/docker"
  local backup_dir="${case_dir}/backup"
  local key_file="${case_dir}/backup-key"
  local output_file="${case_dir}/output.log"
  local state_dir="${case_dir}/container-state"
  local restore_state_dir="${case_dir}/restore-state"
  local migration_preflight_marker="${case_dir}/migration-preflight.invoked"
  local list_marker="${case_dir}/archive-list.invoked"
  local terminate_marker="${case_dir}/database-terminate.invoked"
  local drop_marker="${case_dir}/database-drop.invoked"
  local create_marker="${case_dir}/database-create.invoked"
  local restore_marker="${case_dir}/pg-restore.invoked"
  local staged_container_path_marker="${case_dir}/staged-container-path.txt"
  local cleanup_path_marker="${case_dir}/container-dump-cleanup-path.txt"
  local keyring_restore_marker="${case_dir}/keyring-restore.invoked"
  local keyring_cleanup_marker="${case_dir}/keyring-cleanup.invoked"
  local migration_run_marker="${case_dir}/migration-runner.invoked"
  local migrate_marker="${case_dir}/migrate-tde.invoked"
  local full_start_marker="${case_dir}/full-stack-start.invoked"
  local quiesce_marker="${case_dir}/application-quiesce.invoked"
  local decrypted_path_marker="${case_dir}/decrypted-path.txt"
  local audit_image_marker="${case_dir}/audit-image.invoked"
  local audit_preflight_marker="${case_dir}/audit-preflight.invoked"
  local audit_volume_marker="${case_dir}/audit-volume.invoked"
  local audit_restore_marker="${case_dir}/audit-restore.invoked"

  /bin/mkdir -p "$script_dir" "$backup_dir" "$state_dir" "$restore_state_dir" \
    "${script_dir}/postgres-ssl/server" "${script_dir}/postgres-ssl/ca"
  /bin/cp "$RESTORE_SCRIPT" "${script_dir}/restore-chronicle.sh"
  /bin/cp "$MIGRATE_FIXTURE" "${script_dir}/migrate-tde.sh"
  /bin/chmod 0700 "${script_dir}/restore-chronicle.sh" "${script_dir}/migrate-tde.sh"
  printf 'fixture encryption key\n' > "$key_file"
  printf 'fixture encrypted archive\n' > "${backup_dir}/database.dump.enc"
  printf 'fixture encrypted keyring\n' > "${backup_dir}/tde-keyring.tar.gz.enc"
  printf 'fixture encrypted config\n' > "${backup_dir}/config-secrets.tar.gz.enc"
  printf 'fixture encrypted deployment evidence\n' > "${backup_dir}/deployment-manifest.tar.gz.enc"
  printf 'original-env\n' > "${script_dir}/.env.production.local"
  printf 'original-rhizome\n' > "${script_dir}/rhizome-docker.yaml"
  printf 'original-auth\n' > "${script_dir}/chronicle-auth.yaml"
  printf 'original-server-cert\n' > "${script_dir}/postgres-ssl/server/server.crt"
  printf 'original-server-key\n' > "${script_dir}/postgres-ssl/server/server.key"
  printf 'original-ca\n' > "${script_dir}/postgres-ssl/ca/ca.crt"
  printf 'original-hba\n' > "${script_dir}/postgres-ssl/pg_hba-ssl.conf"
  local audit_artifact=""
  local audit_checksum=""
  if [[ "$CASE_AUDIT_REQUIRED" == true ]]; then
    printf 'fixture encrypted audit logs\n' > "${backup_dir}/audit-logs.tar.gz.enc"
    audit_artifact=',"audit-logs.tar.gz.enc"'
    audit_checksum=',
    "audit-logs.tar.gz.enc":"0000000000000000000000000000000000000000000000000000000000000000"'
  fi
  printf '%s\n' \
    '{' \
    '  "schema_version": 2,' \
    '  "timestamp": "2026-01-01T00:00:00Z",' \
    '  "backup_dir": "fixture",' \
    '  "env_config_file": ".env.production.local",' \
    "  \"audit_logs_required\": ${CASE_AUDIT_REQUIRED}," \
    '  "database_size": "1 MB",' \
    '  "table_count": 7,' \
    '  "tde_encrypted_tables": 7,' \
    '  "tde": {' \
    '    "provider": "file",' \
    '    "provider_name": "chronicle-file-vault",' \
    '    "principal_key_name": "chronicle-principal-key"' \
    '  },' \
    '  "flyway": {' \
    '    "history_format": "jsonb-array-lines/v1",' \
    '    "baseline_version": 54,' \
    '    "max_version": 82,' \
    '    "successful_entry_count": 29,' \
    '    "failed_entry_count": 0,' \
    '    "history_sha256": "0000000000000000000000000000000000000000000000000000000000000000"' \
    '  },' \
    "  \"required_artifacts\": [\"database.dump.enc\",\"tde-keyring.tar.gz.enc\",\"config-secrets.tar.gz.enc\",\"deployment-manifest.tar.gz.enc\"${audit_artifact}]," \
    '  "retention_tags": ["daily"],' \
    '  "checksums": {' \
    '    "database.dump.enc":"0000000000000000000000000000000000000000000000000000000000000000",' \
    '    "tde-keyring.tar.gz.enc":"0000000000000000000000000000000000000000000000000000000000000000",' \
    '    "config-secrets.tar.gz.enc":"0000000000000000000000000000000000000000000000000000000000000000",' \
    "    \"deployment-manifest.tar.gz.enc\":\"0000000000000000000000000000000000000000000000000000000000000000\"${audit_checksum}" \
    '  }' \
    '}' > "${backup_dir}/manifest.json"

  case "$CASE_MANIFEST_MUTATION" in
    none) ;;
    malformed) printf '{invalid-json\n' > "${backup_dir}/manifest.json" ;;
    two-documents) printf '%s\n' '{}' >> "${backup_dir}/manifest.json" ;;
    duplicate-key)
      /usr/bin/sed 's/"schema_version": 2,/"schema_version": 2, "schema_version": 2,/' \
        "${backup_dir}/manifest.json" > "${backup_dir}/manifest.duplicate"
      /bin/mv "${backup_dir}/manifest.duplicate" "${backup_dir}/manifest.json"
      ;;
    path-artifact)
      "$JQ_BIN" '.required_artifacts += ["../../victim.enc"] | .checksums["../../victim.enc"] = ("0" * 64)' \
        "${backup_dir}/manifest.json" > "${backup_dir}/manifest.mutated"
      /bin/mv "${backup_dir}/manifest.mutated" "${backup_dir}/manifest.json"
      ;;
    flyway-hash-short)
      "$JQ_BIN" '.flyway.history_sha256 = ("0" * 32)' "${backup_dir}/manifest.json" \
        > "${backup_dir}/manifest.mutated"
      /bin/mv "${backup_dir}/manifest.mutated" "${backup_dir}/manifest.json"
      ;;
    legacy-v1)
      "$JQ_BIN" 'del(.flyway, .tde) | .schema_version = 1' "${backup_dir}/manifest.json" \
        > "${backup_dir}/manifest.mutated"
      /bin/mv "${backup_dir}/manifest.mutated" "${backup_dir}/manifest.json"
      ;;
    *) fail "${case_name}: unknown manifest mutation ${CASE_MANIFEST_MUTATION}" ;;
  esac

  local responses=$'n\ny'
  [[ "$CASE_RESTORE_CONFIG" == true ]] && responses=$'y\ny'
  [[ "$CASE_AUDIT_REQUIRED" == true ]] && responses+=$'\ny'

  set +e
  PATH="${FIXTURE_COMMANDS}:/usr/bin:/bin" \
    CHRONICLE_RESTORE_JQ="$JQ_BIN" \
    CHRONICLE_RESTORE_STATE_DIR="$restore_state_dir" \
    CHRONICLE_ALLOW_LEGACY_MANIFEST_V1="$CASE_ALLOW_LEGACY_V1" \
    CHRONICLE_LEGACY_TDE_PROVIDER="$CASE_LEGACY_PROVIDER" \
    CHRONICLE_LEGACY_TDE_KEY_NAME="$CASE_LEGACY_KEY_NAME" \
    LEGACY_RESTORE_TEST_KEYRING_TAR_EXIT="$CASE_KEYRING_TAR_EXIT" \
    LEGACY_RESTORE_TEST_KEYRING_MATERIAL="$CASE_KEYRING_MATERIAL" \
    LEGACY_RESTORE_TEST_CONFIG_TAR_EXIT="$CASE_CONFIG_TAR_EXIT" \
    LEGACY_RESTORE_TEST_CONFIG_SHAPE="$CASE_CONFIG_SHAPE" \
    LEGACY_RESTORE_TEST_CONFIG_ENV_NAME=.env.production.local \
    LEGACY_RESTORE_TEST_DEPLOYMENT_TAR_EXIT="$CASE_DEPLOYMENT_TAR_EXIT" \
    LEGACY_RESTORE_TEST_DEPLOYMENT_MANIFEST_VALID="$CASE_DEPLOYMENT_MANIFEST_VALID" \
    LEGACY_RESTORE_TEST_AUDIT_TAR_EXIT="$CASE_AUDIT_TAR_EXIT" \
    LEGACY_RESTORE_TEST_AUDIT_IMAGE_EXIT="$CASE_AUDIT_IMAGE_EXIT" \
    LEGACY_RESTORE_TEST_AUDIT_PREFLIGHT_EXIT="$CASE_AUDIT_PREFLIGHT_EXIT" \
    LEGACY_RESTORE_TEST_AUDIT_VOLUME_EXIT="$CASE_AUDIT_VOLUME_EXIT" \
    LEGACY_RESTORE_TEST_AUDIT_RESTORE_EXIT="$CASE_AUDIT_RESTORE_EXIT" \
    LEGACY_RESTORE_TEST_COMPOSE_DOWN_EXIT="$CASE_COMPOSE_DOWN_EXIT" \
    LEGACY_RESTORE_TEST_CONTAINER_STATE_EXIT="$CASE_CONTAINER_STATE_EXIT" \
    LEGACY_RESTORE_TEST_ARCHIVE_LIST_EXIT="$CASE_ARCHIVE_LIST_EXIT" \
    LEGACY_RESTORE_TEST_PG_RESTORE_EXIT="$CASE_PG_RESTORE_EXIT" \
    LEGACY_RESTORE_TEST_CREATE_DATABASE_EXIT="$CASE_CREATE_DATABASE_EXIT" \
    LEGACY_RESTORE_TEST_KEYRING_RESTORE_EXIT="$CASE_KEYRING_RESTORE_EXIT" \
    LEGACY_RESTORE_TEST_TABLE_QUERY_EXIT="$CASE_TABLE_QUERY_EXIT" \
    LEGACY_RESTORE_TEST_TABLE_COUNT="$CASE_TABLE_COUNT" \
    LEGACY_RESTORE_TEST_SCHEMA_ANCHOR_COUNT="$CASE_SCHEMA_ANCHOR_COUNT" \
    LEGACY_RESTORE_TEST_FLYWAY_MAX="$CASE_FLYWAY_MAX" \
    LEGACY_RESTORE_TEST_FLYWAY_BASELINE="$CASE_FLYWAY_BASELINE" \
    LEGACY_RESTORE_TEST_FLYWAY_SUCCESSFUL="$CASE_FLYWAY_SUCCESSFUL" \
    LEGACY_RESTORE_TEST_FLYWAY_FAILED="$CASE_FLYWAY_FAILED" \
    LEGACY_RESTORE_TEST_FLYWAY_INVALID="$CASE_FLYWAY_INVALID" \
    LEGACY_RESTORE_TEST_FLYWAY_HISTORY_ROW="$CASE_FLYWAY_HISTORY_ROW" \
    LEGACY_RESTORE_TEST_FLYWAY_HISTORY_EXIT="$CASE_FLYWAY_HISTORY_EXIT" \
    LEGACY_RESTORE_TEST_POST_DOWN_BACKEND_RUNNING="$CASE_POST_DOWN_BACKEND_RUNNING" \
    LEGACY_RESTORE_TEST_MIGRATION_PREFLIGHT_EXIT="$CASE_MIGRATION_PREFLIGHT_EXIT" \
    LEGACY_RESTORE_TEST_MIGRATION_RUN_EXIT="$CASE_MIGRATION_RUN_EXIT" \
    LEGACY_RESTORE_TEST_POST_MIGRATION_FLYWAY_MAX="$CASE_POST_MIGRATION_FLYWAY_MAX" \
    LEGACY_RESTORE_TEST_POST_MIGRATION_FLYWAY_FAILED="$CASE_POST_MIGRATION_FLYWAY_FAILED" \
    LEGACY_RESTORE_TEST_TDE_PROVIDER="$CASE_TDE_PROVIDER" \
    LEGACY_RESTORE_TEST_TDE_PROVIDER_NAME="$CASE_TDE_PROVIDER_NAME" \
    LEGACY_RESTORE_TEST_TDE_PROVIDER_TYPE="$CASE_TDE_PROVIDER_TYPE" \
    LEGACY_RESTORE_TEST_TDE_KEY_NAME="$CASE_TDE_KEY_NAME" \
    LEGACY_RESTORE_TEST_TDE_VERIFY_EXIT="$CASE_TDE_VERIFY_EXIT" \
    LEGACY_RESTORE_TEST_CURRENT_TABLE_COUNT="$CASE_CURRENT_TABLE_COUNT" \
    LEGACY_RESTORE_TEST_CURRENT_TDE_COUNT="$CASE_CURRENT_TDE_COUNT" \
    LEGACY_RESTORE_TEST_CURRENT_PLAIN_COUNT="$CASE_CURRENT_PLAIN_COUNT" \
    LEGACY_RESTORE_TEST_DATA_READ_EXIT="$CASE_DATA_READ_EXIT" \
    LEGACY_RESTORE_TEST_FULL_START_EXIT="$CASE_FULL_START_EXIT" \
    LEGACY_RESTORE_TEST_POSTGRES_FINAL_HEALTH_EXIT="$CASE_POSTGRES_FINAL_HEALTH_EXIT" \
    LEGACY_RESTORE_TEST_BACKEND_HEALTH="$CASE_BACKEND_HEALTH" \
    LEGACY_RESTORE_TEST_FRONTEND_HEALTH="$CASE_FRONTEND_HEALTH" \
    LEGACY_RESTORE_TEST_PREPROCESSING_HEALTH="$CASE_PREPROCESSING_HEALTH" \
    LEGACY_RESTORE_TEST_HEALTH_FAILURE_CONTAINER="$CASE_HEALTH_FAILURE_CONTAINER" \
    LEGACY_RESTORE_TEST_FINAL_TABLE_COUNT="$CASE_FINAL_TABLE_COUNT" \
    LEGACY_RESTORE_TEST_FINAL_TDE_COUNT="$CASE_FINAL_TDE_COUNT" \
    LEGACY_RESTORE_TEST_FINAL_PLAIN_COUNT="$CASE_FINAL_PLAIN_COUNT" \
    LEGACY_RESTORE_TEST_MIGRATE_TDE_EXIT="$CASE_MIGRATE_TDE_EXIT" \
    LEGACY_RESTORE_TEST_QUIESCE_EXIT="$CASE_QUIESCE_EXIT" \
    LEGACY_RESTORE_TEST_DIRECT_STOP_EXIT="$CASE_DIRECT_STOP_EXIT" \
    LEGACY_RESTORE_TEST_PRIMARY_STREAMS="$CASE_PRIMARY_STREAMS" \
    LEGACY_RESTORE_TEST_PRIMARY_REPLICATION_QUERY_EXIT="$CASE_PRIMARY_REPLICATION_QUERY_EXIT" \
    LEGACY_RESTORE_TEST_REPLICA_RECOVERY_STATE="$CASE_REPLICA_RECOVERY_STATE" \
    LEGACY_RESTORE_TEST_REPLICA_QUERY_EXIT="$CASE_REPLICA_QUERY_EXIT" \
    LEGACY_RESTORE_TEST_STATE_DIR="$state_dir" \
    LEGACY_RESTORE_TEST_LIST_MARKER="$list_marker" \
    LEGACY_RESTORE_TEST_TERMINATE_MARKER="$terminate_marker" \
    LEGACY_RESTORE_TEST_DROP_MARKER="$drop_marker" \
    LEGACY_RESTORE_TEST_CREATE_MARKER="$create_marker" \
    LEGACY_RESTORE_TEST_RESTORE_MARKER="$restore_marker" \
    LEGACY_RESTORE_TEST_STAGED_CONTAINER_PATH_MARKER="$staged_container_path_marker" \
    LEGACY_RESTORE_TEST_CLEANUP_PATH_MARKER="$cleanup_path_marker" \
    LEGACY_RESTORE_TEST_KEYRING_RESTORE_MARKER="$keyring_restore_marker" \
    LEGACY_RESTORE_TEST_KEYRING_CLEANUP_MARKER="$keyring_cleanup_marker" \
    LEGACY_RESTORE_TEST_MIGRATION_PREFLIGHT_MARKER="$migration_preflight_marker" \
    LEGACY_RESTORE_TEST_MIGRATION_RUN_MARKER="$migration_run_marker" \
    LEGACY_RESTORE_TEST_MIGRATE_MARKER="$migrate_marker" \
    LEGACY_RESTORE_TEST_FULL_START_MARKER="$full_start_marker" \
    LEGACY_RESTORE_TEST_QUIESCE_MARKER="$quiesce_marker" \
    LEGACY_RESTORE_TEST_DECRYPTED_PATH_MARKER="$decrypted_path_marker" \
    LEGACY_RESTORE_TEST_AUDIT_IMAGE_MARKER="$audit_image_marker" \
    LEGACY_RESTORE_TEST_AUDIT_PREFLIGHT_MARKER="$audit_preflight_marker" \
    LEGACY_RESTORE_TEST_AUDIT_VOLUME_MARKER="$audit_volume_marker" \
    LEGACY_RESTORE_TEST_AUDIT_RESTORE_MARKER="$audit_restore_marker" \
    /bin/bash "${script_dir}/restore-chronicle.sh" "$backup_dir" "$key_file" \
      <<< "$responses" > "$output_file" 2>&1
  local result_code=$?
  set -e

  if [[ "$EXPECT_RESULT" == "success" ]]; then
    [[ "$result_code" -eq 0 ]] || fail "${case_name}: expected success, got exit ${result_code}"
  else
    [[ "$result_code" -ne 0 ]] || fail "${case_name}: restore returned success after a fatal condition"
  fi

  if [[ "$EXPECT_KEYRING_RESTORE" == "false" ]]; then
    EXPECT_MIGRATION_RUN=false
  fi

  if [[ "$EXPECT_LIST" == "true" && ! -f "$list_marker" ]]; then
    sed 's/^/child output: /' "$output_file" >&2
  fi
  assert_marker_state "$list_marker" "$EXPECT_LIST" "${case_name}: archive validation"
  assert_marker_state "$migration_preflight_marker" "$EXPECT_PREFLIGHT" "${case_name}: one-shot migration preflight"
  assert_marker_state "$terminate_marker" "$EXPECT_TERMINATE" "${case_name}: session termination"
  assert_marker_state "$drop_marker" "$EXPECT_DROP" "${case_name}: destructive database replacement"
  assert_marker_state "$create_marker" "$EXPECT_CREATE" "${case_name}: replacement database creation"
  assert_marker_state "$restore_marker" "$EXPECT_RESTORE" "${case_name}: pg_restore"
  assert_marker_state "$keyring_restore_marker" "$EXPECT_KEYRING_RESTORE" "${case_name}: TDE keyring replacement"
  assert_marker_state "$keyring_cleanup_marker" "$EXPECT_KEYRING_CLEANUP" "${case_name}: failed TDE keyring staging cleanup"
  assert_marker_state "$migration_run_marker" "$EXPECT_MIGRATION_RUN" "${case_name}: one-shot migration runner"
  assert_marker_state "$migrate_marker" "$EXPECT_MIGRATE" "${case_name}: TDE migration"
  assert_marker_state "$full_start_marker" "$EXPECT_FULL_START" "${case_name}: full application stack start"
  assert_marker_state "$quiesce_marker" "$EXPECT_QUIESCE" "${case_name}: application quiesce"
  assert_marker_state "$audit_image_marker" "$EXPECT_AUDIT_IMAGE" "${case_name}: pinned audit image inspection"
  assert_marker_state "$audit_preflight_marker" "$EXPECT_AUDIT_PREFLIGHT" "${case_name}: audit helper executable preflight"
  assert_marker_state "$audit_volume_marker" "$EXPECT_AUDIT_VOLUME" "${case_name}: audit volume resolution"
  assert_marker_state "$audit_restore_marker" "$EXPECT_AUDIT_RESTORE" "${case_name}: transactional audit restore"

  if [[ "$EXPECT_LIST" == "true" ]]; then
    [[ -s "$staged_container_path_marker" ]] || fail "${case_name}: staged container path was not recorded"
    [[ -s "$cleanup_path_marker" ]] || fail "${case_name}: staged container dump was not cleaned up"
    [[ "$(<"$cleanup_path_marker")" == "$(<"$staged_container_path_marker")" ]] ||
      fail "${case_name}: container cleanup did not target the exact staged dump"
    [[ "$(<"$cleanup_path_marker")" == /tmp/chronicle-restore-*.dump ]] ||
      fail "${case_name}: container dump path is not unique and restore-scoped"
    [[ -s "$decrypted_path_marker" ]] || fail "${case_name}: decrypted dump path was not recorded"
    local decrypted_path
    decrypted_path="$(<"$decrypted_path_marker")"
    [[ ! -e "$decrypted_path" ]] || fail "${case_name}: decrypted host dump was not cleaned up"
  fi

  [[ ! -e "${restore_state_dir}/active.lock" ]] ||
    fail "${case_name}: restore ownership lock was not released"
  if [[ "$CASE_RESTORE_CONFIG" == true && "$EXPECT_RESULT" == success ]]; then
    grep -Fq fixture-env "${script_dir}/.env.production.local" ||
      fail "${case_name}: validated config was not published"
    [[ "$(/usr/bin/stat -f '%Lp' "${script_dir}/postgres-ssl/server/server.key" 2>/dev/null || /usr/bin/stat -c '%a' "${script_dir}/postgres-ssl/server/server.key")" == 600 ]] ||
      fail "${case_name}: restored TLS private key is not mode 0600"
  fi

  grep -Fq "$EXPECT_MESSAGE" "$output_file" ||
    fail "${case_name}: expected operator message was absent: ${EXPECT_MESSAGE}"
  if [[ "$EXPECT_RESULT" == "success" ]]; then
    grep -Fq "Recovery Complete" "$output_file" || fail "${case_name}: success banner was absent"
  elif grep -Fq "Recovery Complete" "$output_file"; then
    fail "${case_name}: success banner was printed after a fatal condition"
  fi
}

reset_case
CASE_KEYRING_TAR_EXIT=44
EXPECT_RESULT=failure
EXPECT_PREFLIGHT=false
EXPECT_LIST=false
EXPECT_TERMINATE=false
EXPECT_DROP=false
EXPECT_CREATE=false
EXPECT_RESTORE=false
EXPECT_KEYRING_RESTORE=false
EXPECT_MIGRATE=false
EXPECT_FULL_START=false
EXPECT_MESSAGE="TDE keyring archive validation failed before database replacement"
run_case "keyring-preflight-failure"

reset_case
CASE_COMPOSE_DOWN_EXIT=45
EXPECT_RESULT=failure
EXPECT_LIST=false
EXPECT_TERMINATE=false
EXPECT_DROP=false
EXPECT_CREATE=false
EXPECT_RESTORE=false
EXPECT_KEYRING_RESTORE=false
EXPECT_MIGRATE=false
EXPECT_FULL_START=false
EXPECT_MESSAGE="Unable to stop all Chronicle services; refusing database replacement"
run_case "shutdown-failure"

reset_case
CASE_POST_DOWN_BACKEND_RUNNING=true
EXPECT_RESULT=failure
EXPECT_LIST=false
EXPECT_TERMINATE=false
EXPECT_DROP=false
EXPECT_CREATE=false
EXPECT_RESTORE=false
EXPECT_KEYRING_RESTORE=false
EXPECT_MIGRATE=false
EXPECT_FULL_START=false
EXPECT_MESSAGE="Service shutdown could not be verified; refusing database replacement"
run_case "shutdown-false-positive"

reset_case
CASE_ARCHIVE_LIST_EXIT=41
EXPECT_RESULT=failure
EXPECT_TERMINATE=false
EXPECT_DROP=false
EXPECT_CREATE=false
EXPECT_RESTORE=false
EXPECT_KEYRING_RESTORE=false
EXPECT_MIGRATE=false
EXPECT_FULL_START=false
EXPECT_MESSAGE="Database archive validation failed before database replacement"
run_case "invalid-archive"

reset_case
CASE_CREATE_DATABASE_EXIT=48
EXPECT_RESULT=failure
EXPECT_RESTORE=false
EXPECT_KEYRING_RESTORE=false
EXPECT_MIGRATE=false
EXPECT_FULL_START=false
EXPECT_MESSAGE="Unable to create the replacement database; refusing to restore"
run_case "database-create-failure"

reset_case
CASE_PG_RESTORE_EXIT=42
EXPECT_RESULT=failure
EXPECT_KEYRING_RESTORE=false
EXPECT_MIGRATE=false
EXPECT_FULL_START=false
EXPECT_MESSAGE="Database restore failed; refusing to start application services"
run_case "pg-restore-failure"

reset_case
CASE_TABLE_QUERY_EXIT=43
EXPECT_RESULT=failure
EXPECT_KEYRING_RESTORE=false
EXPECT_MIGRATE=false
EXPECT_FULL_START=false
EXPECT_MESSAGE="Restore table-count query failed"
run_case "table-query-failure"

reset_case
CASE_TABLE_COUNT=malformed
EXPECT_RESULT=failure
EXPECT_KEYRING_RESTORE=false
EXPECT_MIGRATE=false
EXPECT_FULL_START=false
EXPECT_MESSAGE="Restore postcondition failed: table count is not numeric"
run_case "malformed-table-count"

reset_case
CASE_TABLE_COUNT=0
EXPECT_RESULT=failure
EXPECT_KEYRING_RESTORE=false
EXPECT_MIGRATE=false
EXPECT_FULL_START=false
EXPECT_MESSAGE="Restore postcondition failed: expected at least one public table"
run_case "empty-restore"

reset_case
CASE_TABLE_COUNT=6
EXPECT_RESULT=failure
EXPECT_KEYRING_RESTORE=false
EXPECT_MIGRATE=false
EXPECT_FULL_START=false
EXPECT_MESSAGE="Restore postcondition failed: restored table count 6 does not match manifest 7"
run_case "incomplete-restore"

reset_case
CASE_SCHEMA_ANCHOR_COUNT=4
EXPECT_RESULT=failure
EXPECT_KEYRING_RESTORE=false
EXPECT_MIGRATE=false
EXPECT_FULL_START=false
EXPECT_MESSAGE="Schema postcondition failed: required Chronicle tables are missing"
run_case "wrong-schema"

reset_case
CASE_FLYWAY_FAILED=1
EXPECT_RESULT=failure
EXPECT_KEYRING_RESTORE=false
EXPECT_MIGRATE=false
EXPECT_FULL_START=false
EXPECT_MESSAGE="Migration history postcondition failed"
run_case "failed-migration-history"

reset_case
CASE_KEYRING_RESTORE_EXIT=49
EXPECT_RESULT=failure
EXPECT_KEYRING_CLEANUP=true
EXPECT_MIGRATION_RUN=false
EXPECT_MIGRATE=false
EXPECT_FULL_START=false
EXPECT_MESSAGE="TDE keyring replacement failed before application startup"
run_case "keyring-restore-failure"

reset_case
CASE_MIGRATION_RUN_EXIT=52
EXPECT_RESULT=failure
EXPECT_MIGRATION_RUN=true
EXPECT_MIGRATE=false
EXPECT_FULL_START=false
EXPECT_QUIESCE=false
EXPECT_MESSAGE="One-shot Flyway migration failed"
run_case "migration-runner-failure"

reset_case
CASE_MIGRATE_TDE_EXIT=46
EXPECT_RESULT=failure
EXPECT_FULL_START=false
EXPECT_MESSAGE="TDE migration failed; refusing to start application services"
run_case "tde-migration-failure"

reset_case
CASE_DATA_READ_EXIT=50
EXPECT_RESULT=failure
EXPECT_FULL_START=false
EXPECT_MESSAGE="Restored-data read proof failed"
run_case "restored-data-read-failure"

reset_case
CASE_CURRENT_TDE_COUNT=6
CASE_CURRENT_PLAIN_COUNT=1
EXPECT_RESULT=failure
EXPECT_FULL_START=false
EXPECT_MESSAGE="Pre-ingress TDE postcondition failed"
run_case "pre-ingress-plain-table"

reset_case
CASE_FULL_START_EXIT=51
EXPECT_RESULT=failure
EXPECT_QUIESCE=true
EXPECT_MESSAGE="Full application startup failed; quiescing any partially started services"
run_case "partial-full-startup-failure"

reset_case
CASE_POSTGRES_FINAL_HEALTH_EXIT=47
EXPECT_RESULT=failure
EXPECT_QUIESCE=true
EXPECT_MESSAGE="PostgreSQL is not healthy"
run_case "postgres-health-failure"

reset_case
CASE_BACKEND_HEALTH=unhealthy
EXPECT_RESULT=failure
EXPECT_QUIESCE=true
EXPECT_MESSAGE="Recovery completed with issues"
run_case "backend-health-failure"

reset_case
CASE_FRONTEND_HEALTH=unhealthy
EXPECT_RESULT=failure
EXPECT_QUIESCE=true
EXPECT_MESSAGE="Frontend readiness healthcheck failed"
run_case "frontend-health-failure"

reset_case
CASE_PREPROCESSING_HEALTH=unhealthy
EXPECT_RESULT=failure
EXPECT_QUIESCE=true
EXPECT_MESSAGE="Preprocessing frontend readiness healthcheck failed"
run_case "preprocessing-health-failure"

reset_case
CASE_FINAL_TABLE_COUNT=8
CASE_FINAL_TDE_COUNT=7
CASE_FINAL_PLAIN_COUNT=1
EXPECT_RESULT=failure
EXPECT_QUIESCE=true
EXPECT_MESSAGE="Post-start TDE postcondition failed"
run_case "post-start-encryption-drift"

reset_case
CASE_CURRENT_TABLE_COUNT=8
CASE_CURRENT_TDE_COUNT=8
CASE_FINAL_TABLE_COUNT=8
CASE_FINAL_TDE_COUNT=8
run_case "successful-restore-with-new-encrypted-table"

reset_case
run_case "successful-restore"

echo "legacy restore fail-closed test passed"
