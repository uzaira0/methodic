#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BUILDER="${ROOT_DIR}/scripts/build-selfhost-release.py"
RUN_PARENT="${SELFHOST_RELEASE_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-release}"
BACKEND_IMAGE='ghcr.io/example/chronicle-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
FRONTEND_IMAGE='ghcr.io/example/chronicle-selfhost-frontend@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
CADDY_IMAGE='ghcr.io/example/chronicle-selfhost-caddy@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
PRIVATE_REGISTRY_IMAGE='registry.example.org:5443/chronicle/backend@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'

fail() {
  echo "self-host release bundle test failed: $*" >&2
  exit 1
}

[[ "$RUN_PARENT" == /* ]] || fail "test run parent must be absolute"
case "$RUN_PARENT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
    fail "test run parent must not use a system temporary directory"
    ;;
esac
[[ -x "$BUILDER" ]] || fail "release builder is missing or not executable"

umask 077
/bin/mkdir -p "$RUN_PARENT"
RUN_DIR="$(/usr/bin/mktemp -d "${RUN_PARENT}/run.XXXXXX")"
trap '/bin/rm -rf -- "$RUN_DIR"' EXIT

python3 - "$BUILDER" "$RUN_DIR" <<'PY'
import importlib.util
from pathlib import Path
import sys

builder_path = Path(sys.argv[1])
run_dir = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("selfhost_release_builder", builder_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

release_root = run_dir / "containment-root"
release_root.mkdir()
outside = run_dir / "outside.txt"
outside.write_text("must not be copied\n", encoding="utf-8")
try:
    module.resolve_within(
        release_root,
        release_root / ".." / outside.name,
        strict=True,
        description="test input",
    )
except SystemExit as error:
    if "escapes its release root" not in str(error):
        raise
else:
    raise SystemExit("release path containment helper accepted traversal outside its root")
PY

build_bundle() {
  local output_dir="$1"
  /bin/mkdir -p "$output_dir"
  "$BUILDER" \
    --version v9.8.7-test.1 \
    --source-revision 0123456789abcdef0123456789abcdef01234567 \
    --source-date-epoch 1700000000 \
    --backend-image "$BACKEND_IMAGE" \
    --frontend-image "$FRONTEND_IMAGE" \
    --caddy-image "$CADDY_IMAGE" \
    --output-dir "$output_dir" >/dev/null
}

build_bundle "${RUN_DIR}/first"
build_bundle "${RUN_DIR}/second"

"$BUILDER" \
  --version v9.8.7-private-registry.1 \
  --source-revision 0123456789abcdef0123456789abcdef01234567 \
  --source-date-epoch 1700000000 \
  --backend-image "$PRIVATE_REGISTRY_IMAGE" \
  --frontend-image "$FRONTEND_IMAGE" \
  --caddy-image "$CADDY_IMAGE" \
  --output-dir "${RUN_DIR}/private-registry" >/dev/null \
  || fail "builder rejected an immutable image in a private registry with an explicit port"
grep -Fqx "BACKEND_IMAGE=${PRIVATE_REGISTRY_IMAGE}" \
  "${RUN_DIR}/private-registry/chronicle-selfhost-9.8.7-private-registry.1/selfhost/.env.example" \
  || fail "private-registry image was not rendered into the release bundle"

ARCHIVE="${RUN_DIR}/first/chronicle-selfhost-9.8.7-test.1.tar.gz"
CHECKSUM="${ARCHIVE}.sha256"
BUNDLE="${RUN_DIR}/first/chronicle-selfhost-9.8.7-test.1"
[[ -s "$ARCHIVE" && -s "$CHECKSUM" && -d "$BUNDLE" ]] || fail "builder did not emit all bundle artifacts"

first_hash="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
second_hash="$(sha256sum "${RUN_DIR}/second/$(basename "$ARCHIVE")" | awk '{print $1}')"
[[ "$first_hash" == "$second_hash" ]] || fail "identical inputs did not produce a reproducible archive"
(cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$CHECKSUM")" >/dev/null) \
  || fail "published archive checksum does not verify"

tar -tzf "$ARCHIVE" >"${RUN_DIR}/archive-members.txt"
grep -Fqx 'chronicle-selfhost-9.8.7-test.1/selfhost/docker-compose.yml' "${RUN_DIR}/archive-members.txt" \
  || fail "archive lacks selfhost/docker-compose.yml"
grep -Fqx 'chronicle-selfhost-9.8.7-test.1/docker/init-db-roles.sql' "${RUN_DIR}/archive-members.txt" \
  || fail "archive lacks the database role bootstrap dependency"
grep -Fqx 'chronicle-selfhost-9.8.7-test.1/selfhost/backup-entrypoint.sh' "${RUN_DIR}/archive-members.txt" \
  || fail "archive lacks the restart-safe backup entrypoint"
grep -Fqx 'chronicle-selfhost-9.8.7-test.1/selfhost/upgrade.sh' "${RUN_DIR}/archive-members.txt" \
  || fail "archive lacks the guarded upgrade command"
grep -Fqx 'chronicle-selfhost-9.8.7-test.1/selfhost/rotate-secret.sh' "${RUN_DIR}/archive-members.txt" \
  || fail "archive lacks the guarded secret-rotation command"
grep -Fqx 'chronicle-selfhost-9.8.7-test.1/selfhost/docs/UPGRADE-ROLLBACK.md' "${RUN_DIR}/archive-members.txt" \
  || fail "archive lacks upgrade/rollback recovery instructions"
grep -Fqx 'chronicle-selfhost-9.8.7-test.1/selfhost/docs/SECRET-ROTATION.md' "${RUN_DIR}/archive-members.txt" \
  || fail "archive lacks secret-rotation recovery instructions"
grep -Fqx 'chronicle-selfhost-9.8.7-test.1/selfhost/docs/DEPLOYMENT-COMPATIBILITY.md' "${RUN_DIR}/archive-members.txt" \
  || fail "archive lacks the supported deployment compatibility contract"
grep -Fqx 'chronicle-selfhost-9.8.7-test.1/selfhost/docs/UNINSTALL-DATA-DELETION.md' "${RUN_DIR}/archive-members.txt" \
  || fail "archive lacks data-deletion and complete-uninstall instructions"
if grep -Eq '/(chronicle-server|chronicle-web|chronicle-api|rhizome|gradle)(/|$)|Dockerfile' \
    "${RUN_DIR}/archive-members.txt"; then
  fail "archive contains source/build-tooling paths"
fi
if grep -Fq '/experimental/' "${RUN_DIR}/archive-members.txt"; then
  fail "archive includes an experimental deployment path"
fi

ENV_EXAMPLE="${BUNDLE}/selfhost/.env.example"
env_example_mode="$(stat -c '%a' "$ENV_EXAMPLE" 2>/dev/null || stat -f '%Lp' "$ENV_EXAMPLE")"
[[ "$env_example_mode" == 600 ]] ||
  fail "bundled .env.example mode is ${env_example_mode}; plain cp would expose deployment secrets"
grep -Fqx "BACKEND_IMAGE=${BACKEND_IMAGE}" "$ENV_EXAMPLE" || fail "backend digest was not rendered"
grep -Fqx "SELFHOST_FRONTEND_IMAGE=${FRONTEND_IMAGE}" "$ENV_EXAMPLE" || fail "frontend digest was not rendered"
grep -Fqx "CADDY_IMAGE=${CADDY_IMAGE}" "$ENV_EXAMPLE" || fail "Caddy digest was not rendered"
! grep -Fq '__CHRONICLE_' "$ENV_EXAMPLE" || fail "generated env file retains image placeholders"
grep -Fq './backup-entrypoint.sh:/selfhost/backup-entrypoint.sh:ro' \
  "${BUNDLE}/selfhost/overlays/backups.yml" \
  || fail "backup overlay does not use the bundled readiness wrapper"
grep -Fq 'reverse_proxy /chronicle/study/* backend:40320' \
  "${BUNDLE}/selfhost/caddy/snippets.caddy" \
  || fail "bundle drops the legacy mobile API behind the SPA fallback"
[[ -f "${BUNDLE}/selfhost/monitoring/grafana-datasources.yml" ]] \
  || fail "bundle omits the Grafana metrics/logs data-source provisioning"
for dashboard in system-overview application database-storage containers operational-events operational-logs; do
  [[ -f "${BUNDLE}/selfhost/monitoring/grafana-dashboards/${dashboard}.json" ]] \
    || fail "bundle omits the ${dashboard} monitoring dashboard"
done
[[ -f "${BUNDLE}/selfhost/monitoring/grafana-alerting/rules.yml" ]] \
  || fail "bundle omits dashboard-visible alert provisioning"
[[ -f "${BUNDLE}/selfhost/docs/CAPABILITY-OWNERSHIP.md" ]] \
  || fail "bundle omits generated frontend/backend capability ownership"
[[ -x "${BUNDLE}/selfhost/monitoring/probe.sh" ]] \
  || fail "bundle omits the executable operational probe"
"${ROOT_DIR}/tests/security/selfhost-log-sanitizer.sh" >/dev/null \
  || fail "structured log sanitizer fixtures failed"
[[ -x "${BUNDLE}/selfhost/upgrade.sh" ]] || fail "bundled upgrade command is not executable"
[[ -x "${BUNDLE}/selfhost/rotate-secret.sh" ]] || fail "bundled secret-rotation command is not executable"
[[ -x "${BUNDLE}/selfhost/chronicle" ]] || fail "bundled operator command is not executable"
help_output="$(cd "$BUNDLE" && selfhost/chronicle help)" \
  || fail "bundled operator help fails outside the selfhost directory"
grep -Fq './chronicle doctor [--json]' <<<"$help_output" \
  || fail "bundled operator help omits doctor"
grep -Fq 'deletion-status) cmd_deletion_status' "${BUNDLE}/selfhost/chronicle" \
  || fail "bundled operator command omits deletion proof status"
grep -Fq 'doctor) cmd_doctor' "${BUNDLE}/selfhost/chronicle" \
  || fail "bundled operator command omits actionable diagnostics"
grep -Fq 'monitoring) cmd_monitoring' "${BUNDLE}/selfhost/chronicle" \
  || fail "bundled operator command omits monitoring viewer management"
grep -Fq 'write_operation_receipt()' "${BUNDLE}/selfhost/chronicle" \
  || fail "bundled operator command omits secret-free operation receipts"
grep -Fq 'restore) cmd_restore' "${BUNDLE}/selfhost/chronicle" \
  || fail "bundled operator command omits guarded restore orchestration"
grep -Fq 'CHRONICLE_RESTORE_ORCHESTRATED=true' "${BUNDLE}/selfhost/chronicle" \
  || fail "bundled restore command does not mark an orchestrated one-shot restore"
grep -Fq 'CHRONICLE_EXPORT_DIR: /exports' "${BUNDLE}/selfhost/docker-compose.yml" \
  || fail "bundled backend omits persistent managed export storage"
grep -Fq 'direct restore-service execution is disabled' "${BUNDLE}/selfhost/restore.sh" \
  || fail "bundled restore service permits unsafe direct execution"

# A rejected upgrade must leave a freshly extracted release byte-for-byte eligible for a
# corrected retry. The operator receipt root is not known until upgrade.sh validates the old
# deployment and writes the merged .env; writing a failure receipt earlier pollutes the exact
# bundle inventory and bricks the next attempt.
set +e
(cd "${BUNDLE}/selfhost" && ./chronicle upgrade --from relative-missing) \
  >"${RUN_DIR}/rejected-upgrade.log" 2>&1
rejected_upgrade_status=$?
set -e
[[ "$rejected_upgrade_status" -ne 0 ]] || fail "upgrade accepted a missing previous release"
[[ ! -e "${BUNDLE}/selfhost/operator-receipts" ]] \
  || fail "rejected upgrade polluted the immutable release extraction"
grep -Fq 'previous selfhost directory does not exist' "${RUN_DIR}/rejected-upgrade.log" \
  || fail "rejected upgrade did not explain the invalid previous release"

mapfile -t bundled_modes < <(
  find "${BUNDLE}/selfhost/overlays" -maxdepth 1 -type f -name 'mode-*.yml' -exec basename {} \; | LC_ALL=C sort
)
expected_modes=$'mode-behind-proxy-internal.yml\nmode-local-https.yml\nmode-own-tls-internal.yml'
[[ "$(printf '%s\n' "${bundled_modes[@]}")" == "$expected_modes" ]] \
  || fail "bundle does not contain exactly the three supported deployment modes"
[[ ! -e "${BUNDLE}/selfhost/Caddyfile" && ! -e "${BUNDLE}/selfhost/Caddyfile.tls" ]] \
  || fail "bundle contains obsolete public-dashboard Caddyfiles"
grep -Fq 'CHRONICLE_STATE_DIR=.' "$ENV_EXAMPLE" \
  || fail "bundle omits release-independent mutable state configuration"
grep -Fq 'MOBILE_SIGNING_SECRET_PREVIOUS=' "$ENV_EXAMPLE" \
  || fail "bundle omits the bounded mobile-key overlap setting"
grep -Fqx 'MOBILE_SIGNING_ENABLED=false' "$ENV_EXAMPLE" \
  || fail "bundle does not default controlled legacy mobile HMAC off"
grep -Fqx 'MOBILE_SIGNING_REQUIRED=false' "$ENV_EXAMPLE" \
  || fail "bundle does not default controlled legacy mobile HMAC enforcement off"
grep -Fqx 'MOBILE_SIGNING_SECRET=' "$ENV_EXAMPLE" \
  || fail "bundle requires an unnecessary public-client deployment-wide mobile key"
grep -Fq 'SECRET_ROTATION_WAIT_TIMEOUT_SECONDS=300' "$ENV_EXAMPLE" \
  || fail "bundle omits the bounded secret-rotation wait"
grep -Fq 'RESTORE_START_WAIT_TIMEOUT_SECONDS=300' "$ENV_EXAMPLE" \
  || fail "bundle omits the bounded post-restore health wait"
postgres_service="$({
  awk '
    /^  postgres:$/ { in_postgres = 1; next }
    in_postgres && /^  [[:alnum:]_-]+:$/ { exit }
    in_postgres { print }
  ' "${BUNDLE}/selfhost/docker-compose.yml"
})"
grep -Fq 'start_period: 90s' <<<"$postgres_service" \
  || fail "bundled PostgreSQL healthcheck does not tolerate first-boot initialization"
grep -Fq 'start_period: 240s' "${BUNDLE}/selfhost/docker-compose.yml" \
  || fail "bundled backend healthcheck does not tolerate the encrypted first-boot initialization window"
grep -Fq 'generate_series(0, 65535)' "${BUNDLE}/selfhost/db-init.sh" \
  || fail "bundled database initialization does not seed ID ranges in one transaction"
grep -Fq 'SELECT partition_index, 0, -9223372036854775808' "${BUNDLE}/selfhost/db-init.sh" \
  || fail "bundled database initialization does not preserve the Range initial cursor"
grep -Fq 'partial id_gen bootstrap' "${BUNDLE}/selfhost/db-init.sh" \
  || fail "bundled database initialization does not fail closed on a partial ID range set"
grep -Fq 'first_partition <> 0 OR last_partition <> 65535' "${BUNDLE}/selfhost/db-init.sh" \
  || fail "bundled database initialization does not reject a corrupt ID partition range"
grep -Fq '.chronicle-restore.lock' "${BUNDLE}/selfhost/upgrade.sh" \
  || fail "bundled upgrade does not exclude an active restore"
grep -Fq 'docker compose "${compose_options[@]}"' "${BUNDLE}/selfhost/upgrade.sh" \
  || fail "bundled upgrade does not isolate Compose behind explicit release options"
grep -Fq 'for variable in "${!COMPOSE_@}"' "${BUNDLE}/selfhost/upgrade.sh" \
  || fail "bundled upgrade permits inherited Compose control variables"
grep -Fq 'new release file inventory is not exact' "${BUNDLE}/selfhost/upgrade.sh" \
  || fail "bundled upgrade accepts unlisted files in the new release"
upgrade_stop_line="$(grep -nF 'compose_old stop "${old_application_services[@]}"' \
  "${BUNDLE}/selfhost/upgrade.sh" | cut -d: -f1)"
upgrade_dump_line="$(grep -nF 'if ! compose_old exec -T postgres' \
  "${BUNDLE}/selfhost/upgrade.sh" | cut -d: -f1)"
upgrade_start_line="$(grep -nF 'if ! compose_new up -d --wait' \
  "${BUNDLE}/selfhost/upgrade.sh" | cut -d: -f1)"
[[ "$upgrade_stop_line" =~ ^[0-9]+$ && "$upgrade_dump_line" =~ ^[0-9]+$ &&
    "$upgrade_start_line" =~ ^[0-9]+$ &&
    "$upgrade_stop_line" -lt "$upgrade_dump_line" &&
    "$upgrade_dump_line" -lt "$upgrade_start_line" ]] ||
  fail "bundled upgrade does not stop writers before its rollback dump and new startup"
grep -Fq '.chronicle-restore.lock' "${BUNDLE}/selfhost/rotate-secret.sh" \
  || fail "bundled secret rotation does not exclude an active restore"
grep -Fq "IF (SELECT key_name FROM pg_tde_key_info()) IS NULL THEN" \
  "${BUNDLE}/selfhost/init-tde.sh" \
  || fail "bundle would reset a rotated TDE principal key during db-init"

python3 - "$BUNDLE" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

bundle = Path(sys.argv[1])
manifest = json.loads((bundle / "release-manifest.json").read_text(encoding="utf-8"))
assert manifest["schema_version"] == 1
assert manifest["release_version"] == "9.8.7-test.1"
assert manifest["source_revision"] == "0123456789abcdef0123456789abcdef01234567"
for relative, expected in manifest["files"].items():
    actual = hashlib.sha256((bundle / relative).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"checksum mismatch: {relative}")
PY

setup_password='turnkey-dashboard-password-123!'
printf '1\nturnkey.example.org\n\n\n%s\n%s\n\n\n\n\n\n' "$setup_password" "$setup_password" |
  (cd "${BUNDLE}/selfhost" && \
    CADDY_SETUP_HASH_IMAGE='caddy:2.10.2-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d' \
    ./chronicle setup) >"${RUN_DIR}/turnkey-setup.log" 2>&1 \
  || { cat "${RUN_DIR}/turnkey-setup.log" >&2; fail "interactive turnkey setup failed"; }
! grep -Fq "$setup_password" "${RUN_DIR}/turnkey-setup.log" || fail "setup printed its dashboard password"
grep -Fq 'Next:  ./chronicle up' "${RUN_DIR}/turnkey-setup.log" || fail "setup did not give the guarded startup command"
setup_env_mode="$(stat -c '%a' "${BUNDLE}/selfhost/.env" 2>/dev/null || stat -f '%Lp' "${BUNDLE}/selfhost/.env")"
[[ "$setup_env_mode" == 600 ]] || fail "turnkey setup did not protect .env"
grep -Fq ':overlays/monitoring.yml' "${BUNDLE}/selfhost/.env" || fail "turnkey setup did not enable selected monitoring"
setup_receipt="$(find "${BUNDLE}/selfhost/operator-receipts/operations" -type f -name '*-setup-*.json' -print -quit)"
[[ -n "$setup_receipt" ]] || fail "turnkey setup did not write an operation receipt"
python3 - "$setup_receipt" <<'PY'
import json, sys
receipt = json.load(open(sys.argv[1], encoding="utf-8"))
assert receipt["operation"] == "setup"
assert receipt["outcome"] == "success"
assert receipt["failureCategory"] == "none"
assert set(receipt) == {"operation", "timestamp", "releaseVersion", "outcome", "failureCategory"}
PY

(cd "${BUNDLE}/selfhost" && ./verify-config.sh >/dev/null) \
  || fail "standalone bundle config contract failed"
SELFHOST_MATRIX_ROOT="${BUNDLE}/selfhost" \
  SELFHOST_MATRIX_TEST_ROOT="${RUN_DIR}/bundle-matrix" \
  "${ROOT_DIR}/tests/security/selfhost-combination-matrix.sh" >/dev/null \
  || fail "standalone bundle supported-combination matrix failed"

/bin/cp "$ENV_EXAMPLE" "${BUNDLE}/selfhost/.env"
copied_env_mode="$(stat -c '%a' "${BUNDLE}/selfhost/.env" 2>/dev/null || stat -f '%Lp' "${BUNDLE}/selfhost/.env")"
[[ "$copied_env_mode" == 600 ]] || fail "cp .env.example .env did not retain private mode 0600"
(cd "${BUNDLE}/selfhost" && docker compose config --images >"${RUN_DIR}/compose-images.txt") \
  || fail "standalone bundle does not render with Docker Compose"
for expected_image in "$BACKEND_IMAGE" "$FRONTEND_IMAGE" "$CADDY_IMAGE"; do
  grep -Fqx "$expected_image" "${RUN_DIR}/compose-images.txt" \
    || fail "rendered Compose omits release image: ${expected_image}"
done
if (cd "${BUNDLE}/selfhost" && docker compose config --format json | jq -e \
    'any(.services[]; has("build"))' >/dev/null); then
  fail "rendered release Compose contains a build definition"
fi

set +e
"$BUILDER" \
  --version v9.8.8 \
  --source-revision 0123456789abcdef0123456789abcdef01234567 \
  --source-date-epoch 1700000000 \
  --backend-image ghcr.io/example/chronicle-backend:latest \
  --frontend-image "$FRONTEND_IMAGE" \
  --caddy-image "$CADDY_IMAGE" \
  --output-dir "${RUN_DIR}/invalid" >"${RUN_DIR}/invalid.log" 2>&1
invalid_status=$?
set -e
[[ "$invalid_status" -ne 0 ]] || fail "builder accepted a mutable backend image"
grep -Fq 'must be an immutable name@sha256 reference' "${RUN_DIR}/invalid.log" \
  || fail "mutable-image rejection was not comprehensible"

invalid_version_index=0
for invalid_version in v01.2.3 v1.2.3-01 v1.2.3-rc.; do
  invalid_version_index=$((invalid_version_index + 1))
  set +e
  "$BUILDER" \
    --version "$invalid_version" \
    --source-revision 0123456789abcdef0123456789abcdef01234567 \
    --source-date-epoch 1700000000 \
    --backend-image "$BACKEND_IMAGE" \
    --frontend-image "$FRONTEND_IMAGE" \
    --caddy-image "$CADDY_IMAGE" \
    --output-dir "${RUN_DIR}/invalid-version-${invalid_version_index}" \
    >"${RUN_DIR}/invalid-version-${invalid_version_index}.log" 2>&1
  invalid_status=$?
  set -e
  [[ "$invalid_status" -ne 0 ]] ||
    fail "builder accepted invalid semantic version: $invalid_version"
done

overflow_dir="${RUN_DIR}/invalid-source-date"
set +e
"$BUILDER" \
  --version v9.8.9 \
  --source-revision 0123456789abcdef0123456789abcdef01234567 \
  --source-date-epoch 4294967296 \
  --backend-image "$BACKEND_IMAGE" \
  --frontend-image "$FRONTEND_IMAGE" \
  --caddy-image "$CADDY_IMAGE" \
  --output-dir "$overflow_dir" >"${RUN_DIR}/invalid-source-date.log" 2>&1
invalid_status=$?
set -e
[[ "$invalid_status" -ne 0 ]] || fail "builder accepted a source date outside gzip's range"
grep -Fq 'must fit the gzip timestamp range' "${RUN_DIR}/invalid-source-date.log" \
  || fail "invalid source-date rejection was not comprehensible"
if [[ -d "$overflow_dir" ]] && find "$overflow_dir" -mindepth 1 -print -quit | grep -q .; then
  fail "builder published partial outputs after rejecting an invalid archive timestamp"
fi

echo "self-host release bundle test passed"
