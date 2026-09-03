#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RUN_PARENT="${PUBLIC_DISTRIBUTION_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/public-distribution-integration}"
failures=0

[[ "$RUN_PARENT" == /* ]] || { printf 'test run parent must be absolute\n' >&2; exit 2; }
case "$RUN_PARENT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*)
    printf 'test run parent must not use a system temporary directory\n' >&2
    exit 2
    ;;
esac
umask 077
/bin/mkdir -p "$RUN_PARENT"
/bin/chmod 0700 "$RUN_PARENT"
RUN_DIR="$(/usr/bin/mktemp -d "${RUN_PARENT}/run.XXXXXX")"
/bin/chmod 0700 "$RUN_DIR"
trap '/bin/rm -rf -- "$RUN_DIR"' EXIT

fail() {
  printf 'public distribution integration guard failed: %s\n' "$*" >&2
  failures=$((failures + 1))
}

require_literal() {
  local file="$1" literal="$2" description="$3"
  grep -Fq -- "$literal" "$ROOT_DIR/$file" || fail "$description"
}

reject_pattern() {
  local file="$1" pattern="$2" description="$3"
  ! grep -Eq -- "$pattern" "$ROOT_DIR/$file" || fail "$description"
}

BUILD_WORKFLOW=.github/workflows/build-android-apk.yml
MAESTRO_WORKFLOW=.github/workflows/maestro-android-test.yml

for workflow in "$BUILD_WORKFLOW" "$MAESTRO_WORKFLOW"; do
  reject_pattern "$workflow" 'android_ref:|Select Android ref|git fetch --no-tags origin' \
    "$workflow must build the Android revision pinned by the committed submodule gitlink"
done
reject_pattern docker/build-apk.sh 'android_ref|server_url|git-credentials|export PATH=.*/tmp' \
  'the Android workflow wrapper must use the pinned gitlink and protected GitHub CLI/output paths'
require_literal docker/build-apk.sh '-f "distribution=$DISTRIBUTION"' \
  'the Android workflow wrapper must dispatch the selected public distribution'
reject_pattern "$MAESTRO_WORKFLOW" 'mobileSigningSecret|MOBILE_SIGNING_SECRET' \
  'Maestro public-flavor builds must not require or pass a deployment-wide HMAC secret'
require_literal tests/security/mobile-upload-guardrails.sh 'CHRONICLE_REQUIRE_MOBILE_SIGNING_SECRET:-0' \
  'the canonical mobile guard must exercise the public secret-free contract by default'
require_literal "$BUILD_WORKFLOW" "if: inputs.distribution == 'play' || inputs.distribution == 'amazon'" \
  'the public Android build step must be isolated from controlled-legacy inputs'
reject_pattern "$BUILD_WORKFLOW" '^      SERVER_HOST:' \
  'the controlled research deployment host must not be inherited by public build steps'
require_literal "$BUILD_WORKFLOW" 'ORG_GRADLE_PROJECT_mobileSigningSecret: ${{ secrets.MOBILE_SIGNING_SECRET }}' \
  'the controlled research build must deliberately inject its legacy signing key without putting it in process argv'
reject_pattern "$BUILD_WORKFLOW" 'play[^\n]*(chronicleProductionHost|mobileSigningSecret)|amazon[^\n]*(chronicleProductionHost|mobileSigningSecret)' \
  'Play and Amazon builds must not receive a fixed deployment host or shared HMAC secret'

for env_file in docker/.env.example docker/.env.production docker/.env.staging; do
  require_literal "$env_file" 'MOBILE_SIGNING_ENABLED=false' \
    "$env_file must default controlled legacy HMAC off"
  require_literal "$env_file" 'MOBILE_SIGNING_REQUIRED=false' \
    "$env_file must default controlled legacy HMAC enforcement off"
  require_literal "$env_file" 'MOBILE_SIGNING_SECRET=' \
    "$env_file must leave the controlled-legacy key blank by default"
  reject_pattern "$env_file" '^MOBILE_SIGNING_SECRET=.+$' \
    "$env_file must not force a deployment-wide mobile signing key"
done

require_literal docker/docker-compose.traefik.yml 'MOBILE_SIGNING_ENABLED: ${MOBILE_SIGNING_ENABLED:-false}' \
  'production Compose must default controlled legacy HMAC off'
require_literal docker/docker-compose.traefik.yml 'MOBILE_SIGNING_REQUIRED: ${MOBILE_SIGNING_REQUIRED:-false}' \
  'production Compose must default controlled legacy HMAC enforcement off'
reject_pattern docker/docker-compose.traefik.yml 'production requires MOBILE_SIGNING_(ENABLED|REQUIRED)=true' \
  'production Compose must not force controlled legacy HMAC on'
reject_pattern docker/docker-compose.traefik.yml '^[[:space:]]+- mobile_signing_secret$|^[[:space:]]+mobile_signing_secret:$' \
  'the public Docker stack must not require a legacy signing secret file'

require_literal k8s/base/backend.yaml 'name: MOBILE_SIGNING_ENABLED' \
  'Kubernetes backend must declare the controlled-legacy enable flag'
require_literal k8s/base/backend.yaml 'value: "false"' \
  'Kubernetes backend must include disabled public-client defaults'
reject_pattern k8s/base/backend.yaml 'production requires mobile signing enabled and required' \
  'Kubernetes startup must not force controlled legacy HMAC on'
reject_pattern k8s/base/external-secrets.yaml 'secretKey:[[:space:]]*MOBILE_SIGNING_SECRET' \
  'Kubernetes public defaults must not require a remote legacy signing key'
reject_pattern deploy/ansible/inventory/group_vars/all.yml 'MOBILE_SIGNING_SECRET:[[:space:]]*\{[[:space:]]*min_bytes:' \
  'Ansible public deployment validation must not require a legacy signing key'

reject_pattern scripts/deploy.sh 'require_env_value .*MOBILE_SIGNING_SECRET' \
  'production deploy validation must not require a legacy signing key'
reject_pattern scripts/deploy.sh 'require_env_equals .*MOBILE_SIGNING_(ENABLED|REQUIRED).*true' \
  'production deploy validation must not force controlled legacy HMAC on'

reject_pattern scripts/verify-schema-postconditions.sh 'docker[[:space:]]+exec([^\n]|\\\n)*-e[[:space:]]+PGPASSWORD=' \
  'schema verification must not expose PGPASSWORD in host process arguments'
require_literal scripts/verify-schema-postconditions.sh 'IFS= read -r PGPASSWORD' \
  'schema verification must deliver PGPASSWORD over the container stdin channel'

# Execute the complete verifier against a fake Docker client. The sentinel may arrive only
# as the first stdin record; it must be absent from Docker argv and verifier output.
SCHEMA_SENTINEL='schema-password-stdin-only-sentinel-948271'
SCHEMA_ENV="$RUN_DIR/schema.env"
COMMAND_DIR="$RUN_DIR/commands"
DOCKER_ARGV="$RUN_DIR/docker.argv"
SCHEMA_OUTPUT="$RUN_DIR/schema-verifier.out"
/bin/mkdir -p "$COMMAND_DIR"
cat >"$SCHEMA_ENV" <<EOF
POSTGRES_USER=chronicle
POSTGRES_PASSWORD=$SCHEMA_SENTINEL
POSTGRES_DB=chronicle
EOF
/bin/chmod 0600 "$SCHEMA_ENV"
cat >"$COMMAND_DIR/docker" <<'DOCKER_FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  [[ "$argument" != *"${SCHEMA_SENTINEL:?}"* ]] || {
    printf 'schema password reached Docker argv\n' >&2
    exit 91
  }
done
printf '%q ' "$@" >>"${DOCKER_ARGV:?}"
printf '\n' >>"$DOCKER_ARGV"
[[ "${1:-}" == exec && "${2:-}" == -i ]] || {
  printf 'schema verifier did not use Docker stdin\n' >&2
  exit 92
}
IFS= read -r received_password
IFS= read -r query
[[ "$received_password" == "$SCHEMA_SENTINEL" ]] || {
  printf 'schema password did not arrive as the first stdin record\n' >&2
  exit 93
}
[[ -n "$query" ]] || exit 94
case "$query" in
  'SELECT 1') printf '1\n' ;;
  *"to_regclass('public.flyway_schema_history')"*) printf 't\n' ;;
  *'FROM flyway_schema_history WHERE NOT success'*) printf '0\n' ;;
  *'MAX(version::int)'*"type = 'BASELINE'"*) printf '0\n' ;;
  *'MAX(version::int)'*) printf '%s\n' "${SCHEMA_EXPECTED_MAX:?}" ;;
  *"type = 'SQL'"*) printf '%s\n' "${SCHEMA_EXPECTED_ROWS:?}" ;;
  *'relrowsecurity'*) printf 'true/true\n' ;;
  *"has_table_privilege('chronicle_app', 'public.mobile_withdrawal_requests', 'INSERT')"*) printf 't\n' ;;
  *"has_table_privilege('chronicle_admin', 'public.restore_continuity_reconciliations', 'SELECT')"*) printf 't\n' ;;
  *'has_table_privilege'*) printf 'f\n' ;;
  *'has_schema_privilege'*|*'has_function_privilege'*) printf 'f\n' ;;
  *'FROM pg_policies'*) printf '32\n' ;;
  *'FROM pg_trigger'*) printf '1\n' ;;
  *"to_regclass('public."*) printf 't\n' ;;
  *) printf 'unexpected schema query: %s\n' "$query" >&2; exit 95 ;;
esac
DOCKER_FIXTURE
/bin/chmod 0700 "$COMMAND_DIR/docker"
SCHEMA_EXPECTED_MAX="$(find "$ROOT_DIR/chronicle-server/src/main/resources/db/migration" -maxdepth 1 -name 'V*.sql' -print |
  sed -E 's/.*V([0-9]+)__.*/\1/' | sort -n | tail -n 1)"
SCHEMA_EXPECTED_ROWS="$(find "$ROOT_DIR/chronicle-server/src/main/resources/db/migration" -maxdepth 1 -name 'V*.sql' -print | wc -l | tr -d ' ')"
if ! PATH="$COMMAND_DIR:$PATH" \
  SCHEMA_SENTINEL="$SCHEMA_SENTINEL" \
  DOCKER_ARGV="$DOCKER_ARGV" \
  SCHEMA_EXPECTED_MAX="$SCHEMA_EXPECTED_MAX" \
  SCHEMA_EXPECTED_ROWS="$SCHEMA_EXPECTED_ROWS" \
  CHRONICLE_ENV_FILE="$SCHEMA_ENV" \
  CHRONICLE_PG_CONTAINER=fixture-postgres \
  CHRONICLE_SKIP_TDE_CHECK=1 \
  "$ROOT_DIR/scripts/verify-schema-postconditions.sh" >"$SCHEMA_OUTPUT" 2>&1; then
  sed "s/${SCHEMA_SENTINEL}/[redacted-sentinel]/g" "$SCHEMA_OUTPUT" >&2
  fail 'schema verifier failed against its stdin-only password fixture'
fi
if grep -Fq "$SCHEMA_SENTINEL" "$DOCKER_ARGV" "$SCHEMA_OUTPUT"; then
  fail 'schema verifier exposed the password sentinel in argv or output'
fi

python3 - "$ROOT_DIR/selfhost/chronicle" <<'PY' || fail 'selfhost/chronicle must set a private umask before setup and atomically create its protected env file'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
setup = source.index("cmd_setup()")
umask = source.index("umask 077")
if umask > setup:
    raise SystemExit("private umask is set after setup code")
required = ("tempfile.mkstemp(prefix='.env.setup-', dir='.')", "os.fchmod(descriptor, 0o600)", "os.replace(temporary, '.env')")
if any(token not in source for token in required):
    raise SystemExit("protected atomic env publication is incomplete")
if "cp .env.example .env" in source:
    raise SystemExit("setup still overwrites the live env file before atomic publication")
PY

require_literal selfhost/backend-entrypoint.sh '"${CHRONICLE_PUBLIC_BASE_URL}"' \
  'backend CORS assembly must include the canonical public application origin'
require_literal selfhost/backend-entrypoint.sh 'CHRONICLE_PUBLIC_BASE_URL must be an exact HTTPS root origin' \
  'backend entrypoint must validate the canonical public application origin'
require_literal docker/mobile-security.yaml.template 'public-base-url: "${CHRONICLE_PUBLIC_BASE_URL}"' \
  'Docker mobile manifests must use the canonical public application origin'
require_literal docker/docker-compose.traefik.yml 'CHRONICLE_PUBLIC_BASE_URL: ${CHRONICLE_PUBLIC_BASE_URL:-https://${DOMAIN}}' \
  'Docker backend must receive an explicit canonical public application origin'
require_literal k8s/base/config-templates/mobile-security.yaml.template 'public-base-url: "${CHRONICLE_PUBLIC_BASE_URL}"' \
  'Kubernetes mobile manifests must use the canonical public application origin'
require_literal k8s/base/backend.yaml 'name: CHRONICLE_PUBLIC_BASE_URL' \
  'Kubernetes backend must receive the canonical public application origin'

python3 - "$ROOT_DIR/.github/workflows/cd.yml" \
  "$ROOT_DIR/docker/Dockerfile.backend" \
  "$ROOT_DIR/docker/Dockerfile.frontend.prod" \
  "$ROOT_DIR/selfhost/Dockerfile.frontend" \
  "$ROOT_DIR/selfhost/Dockerfile.caddy" <<'PY' || fail 'CD block-mode egress does not cover the exact current Docker/Gradle/Bun/Go fetch paths'
from pathlib import Path
import re
import sys

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
dockerfiles = "\n".join(Path(path).read_text(encoding="utf-8") for path in sys.argv[2:])
match = re.search(r"allowed-endpoints:\s*>\s*\n(?P<body>(?:\s{12}\S.*\n)+)", workflow)
if not match:
    raise SystemExit("build-images allowed-endpoints block was not found")
endpoints = {line.strip() for line in match.group("body").splitlines() if line.strip()}

expected = {
    "services.gradle.org:443",
    "release-assets.githubusercontent.com:443",
    "downloads.gradle.org:443",
    "plugins.gradle.org:443",
    "plugins-artifacts.gradle.org:443",
    "repo.maven.apache.org:443",
    "registry.npmjs.org:443",
    "archive.ubuntu.com:80",
    "security.ubuntu.com:80",
    "dl-cdn.alpinelinux.org:443",
    "proxy.golang.org:443",
    "sum.golang.org:443",
    "storage.googleapis.com:443",
}
missing = sorted(expected - endpoints)
if missing:
    raise SystemExit("missing endpoints: " + ", ".join(missing))
for obsolete in ("dl.google.com:443", "repo1.maven.org:443"):
    if obsolete in endpoints:
        raise SystemExit("unneeded endpoint remains: " + obsolete)
if "apt-get" not in dockerfiles or "apk add" not in dockerfiles:
    raise SystemExit("Dockerfile package-manager paths disappeared without updating this guard")
if "./gradlew" not in dockerfiles or "bun install" not in dockerfiles or "xcaddy build" not in dockerfiles:
    raise SystemExit("Dockerfile dependency-fetch paths disappeared without updating this guard")
PY

for sql_file in docker/init-db-roles.sql k8s/base/postgres-init/10-init-db-roles.sql; do
  require_literal "$sql_file" "'audit'" "$sql_file must protect the final audit table"
  require_literal "$sql_file" "'audit_buffer'" "$sql_file must protect the final audit buffer"
  require_literal "$sql_file" 'REVOKE UPDATE, DELETE, TRUNCATE' \
    "$sql_file must revoke every destructive audit-table privilege"
done
for init_script in docker/init-audit-immutability.sh k8s/base/postgres-init/30-init-audit-immutability.sh; do
  require_literal "$init_script" 'REVOKE DELETE, UPDATE, TRUNCATE ON audit FROM chronicle_app, chronicle_admin;' \
    "$init_script must revoke final audit-table mutation from both runtime roles"
  require_literal "$init_script" 'REVOKE DELETE, UPDATE, TRUNCATE ON audit_buffer FROM chronicle_app, chronicle_admin;' \
    "$init_script must revoke final audit-buffer mutation from both runtime roles"
done
for table in audit audit_buffer; do
  for privilege in UPDATE DELETE TRUNCATE; do
    require_literal scripts/verify-schema-postconditions.sh "${table}:${privilege}" \
      "live schema verification must check ${table} ${privilege} immutability"
  done
done

if ((failures > 0)); then
  printf 'public distribution integration guard failed with %d finding(s)\n' "$failures" >&2
  exit 1
fi
printf 'public distribution integration guard passed\n'
