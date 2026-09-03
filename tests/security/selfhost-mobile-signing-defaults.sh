#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SELFHOST_DIR="$ROOT_DIR/selfhost"
ENV_EXAMPLE="$SELFHOST_DIR/.env.example"
COMPOSE_FILE="$SELFHOST_DIR/docker-compose.yml"
GUARD="$SELFHOST_DIR/guard-config.sh"
ENTRYPOINT="$SELFHOST_DIR/backend-entrypoint.sh"
ROTATE_SECRET="$SELFHOST_DIR/rotate-secret.sh"
RUN_PARENT="${SELFHOST_MOBILE_SIGNING_TEST_ROOT:-${ROOT_DIR}/build/operator-test-runs/selfhost-mobile-signing}"

fail() {
  printf 'self-host mobile-signing defaults test failed: %s\n' "$*" >&2
  exit 1
}

for required in "$ENV_EXAMPLE" "$COMPOSE_FILE" "$GUARD" "$ENTRYPOINT" "$ROTATE_SECRET"; do
  [[ -f "$required" ]] || fail "required file is missing: $required"
done

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

[[ "$(grep -E '^MOBILE_SIGNING_ENABLED=' "$ENV_EXAMPLE")" == 'MOBILE_SIGNING_ENABLED=false' ]] ||
  fail ".env.example must disable legacy mobile HMAC by default"
[[ "$(grep -E '^MOBILE_SIGNING_REQUIRED=' "$ENV_EXAMPLE")" == 'MOBILE_SIGNING_REQUIRED=false' ]] ||
  fail ".env.example must not require legacy mobile HMAC by default"
[[ "$(grep -E '^MOBILE_SIGNING_SECRET=' "$ENV_EXAMPLE")" == 'MOBILE_SIGNING_SECRET=' ]] ||
  fail ".env.example must leave the deployment-wide legacy key blank by default"

grep -Fq 'MOBILE_SIGNING_ENABLED: ${MOBILE_SIGNING_ENABLED:-false}' "$COMPOSE_FILE" ||
  fail "Compose must default legacy mobile HMAC off"
grep -Fq 'MOBILE_SIGNING_REQUIRED: ${MOBILE_SIGNING_REQUIRED:-false}' "$COMPOSE_FILE" ||
  fail "Compose must default legacy mobile HMAC enforcement off"
grep -Fq 'MOBILE_SIGNING_SECRET: ${MOBILE_SIGNING_SECRET:-}' "$COMPOSE_FILE" ||
  fail "Compose must allow a blank legacy mobile signing key"
[[ "$(grep -Fc 'MOBILE_SIGNING_ENABLED: ${MOBILE_SIGNING_ENABLED:-false}' "$COMPOSE_FILE")" -eq 2 ]] ||
  fail "both the configuration guard and backend must receive the effective legacy-HMAC opt-in"
grep -Fq 'controlled legacy mobile HMAC compatibility is disabled; public per-device-key clients require no shared-key rotation' "$ROTATE_SECRET" ||
  fail "the mobile rotation command must refuse a disabled legacy-compatibility mode"

guard_case() {
  local name="$1" expected_status="$2" enabled="$3" required="$4" current="$5" previous="$6" expected_text="$7"
  local output="$RUN_DIR/guard-${name}.log" result_code
  set +e
  env -i \
    PATH="${PATH}" \
    TLS_MODE=behind-proxy \
    DASHBOARD_EXPOSURE=internal \
    COMPOSE_FILE_SELECTION='docker-compose.yml:overlays/mode-behind-proxy-internal.yml:overlays/backups.yml' \
    BACKUPS_ENABLED=true \
    AUTH_OVERLAY_ENABLED=false \
    MONITORING_ENABLED=false \
    ENABLE_ENCRYPTION=false \
    DOMAIN=mobile-signing.example.org \
    POSTGRES_PASSWORD=fixture-postgres-password-not-a-secret \
    MOBILE_SIGNING_ENABLED="$enabled" \
    MOBILE_SIGNING_REQUIRED="$required" \
    MOBILE_SIGNING_SECRET="$current" \
    MOBILE_SIGNING_SECRET_PREVIOUS="$previous" \
    CHRONICLE_INTERNAL_WEB_SECRET=fixture-internal-web-secret-not-a-secret-12345 \
    JWT_SECRET=fixture-jwt-signing-secret-not-a-secret-123456 \
    METRICS_PASSWORD=fixture-metrics-password-not-a-secret-123456 \
    TESTING_LOGIN_ENABLED=true \
    REQUIRE_MFA=false \
    INTERNAL_BIND=127.0.0.1 \
    INTERNAL_PORT=8081 \
    HTTP_BIND=127.0.0.1 \
    DASHBOARD_PASSWORD_HASH='$2b$12$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    DASHBOARD_ALLOWED_IPS='127.0.0.1/32' \
    /bin/bash "$GUARD" >"$output" 2>&1
  result_code=$?
  set -e
  if [[ "$expected_status" == pass ]]; then
    [[ "$result_code" -eq 0 ]] || fail "guard rejected ${name}: $(tr '\n' ' ' <"$output")"
  else
    [[ "$result_code" -ne 0 ]] || fail "guard accepted inconsistent legacy opt-in: ${name}"
    grep -Fq "$expected_text" "$output" ||
      fail "guard rejection for ${name} omitted '${expected_text}'"
  fi
}

legacy_current='fixture-current-legacy-mobile-signing-secret-12345'
legacy_previous='fixture-previous-legacy-mobile-signing-secret-1234'

guard_case public-default pass false false '' '' ''
guard_case legacy-enabled pass true true "$legacy_current" '' ''
guard_case invalid-enabled reject treu false '' '' 'MOBILE_SIGNING_ENABLED must be exactly true or false'
guard_case required-without-enabled reject false true '' '' 'must either both be true or both be false'
guard_case enabled-without-required reject true false "$legacy_current" '' 'must either both be true or both be false'
guard_case enabled-without-secret reject true true '' '' 'MOBILE_SIGNING_SECRET must be a generated 32+ character key'
guard_case disabled-with-secret reject false false "$legacy_current" '' 'must stay blank unless controlled legacy compatibility is enabled'
guard_case disabled-with-previous reject false false '' "$legacy_previous" 'must stay blank unless controlled legacy compatibility is enabled'

entrypoint_case() {
  local name="$1" expected_status="$2" enabled="$3" required="$4" current="$5" previous="$6" expected_text="$7"
  local output="$RUN_DIR/entrypoint-${name}.log" result_code
  set +e
  env -i \
    PATH="${PATH}" \
    MOBILE_SIGNING_ENABLED="$enabled" \
    MOBILE_SIGNING_REQUIRED="$required" \
    MOBILE_SIGNING_SECRET="$current" \
    MOBILE_SIGNING_SECRET_PREVIOUS="$previous" \
    /bin/sh "$ENTRYPOINT" --validate-mobile-signing >"$output" 2>&1
  result_code=$?
  set -e
  if [[ "$expected_status" == pass ]]; then
    [[ "$result_code" -eq 0 ]] || fail "entrypoint rejected ${name}: $(tr '\n' ' ' <"$output")"
  else
    [[ "$result_code" -ne 0 ]] || fail "entrypoint accepted inconsistent legacy opt-in: ${name}"
    grep -Fq "$expected_text" "$output" ||
      fail "entrypoint rejection for ${name} omitted '${expected_text}'"
  fi
}

entrypoint_case public-default pass false false '' '' ''
entrypoint_case legacy-enabled pass true true "$legacy_current" '' ''
entrypoint_case mismatch reject false true '' '' 'must either both be true or both be false'
entrypoint_case missing-secret reject true true '' '' 'MOBILE_SIGNING_SECRET must be a generated 32+ character key'
entrypoint_case disabled-secret reject false false "$legacy_current" '' 'must stay blank unless controlled legacy compatibility is enabled'

if ! env -i PATH="${PATH}" \
  CHRONICLE_PUBLIC_BASE_URL=https://participants.example.org \
  MOBILE_SIGNING_ENABLED=false MOBILE_SIGNING_REQUIRED=false \
  MOBILE_SIGNING_SECRET='' MOBILE_SIGNING_SECRET_PREVIOUS='' \
  /bin/sh "$ENTRYPOINT" --validate-mobile-signing >/dev/null 2>&1; then
  fail "entrypoint rejected a distinct valid public application origin"
fi
if env -i PATH="${PATH}" \
  CHRONICLE_PUBLIC_BASE_URL='https://participants.example.org/path' \
  MOBILE_SIGNING_ENABLED=false MOBILE_SIGNING_REQUIRED=false \
  MOBILE_SIGNING_SECRET='' MOBILE_SIGNING_SECRET_PREVIOUS='' \
  /bin/sh "$ENTRYPOINT" --validate-mobile-signing >"$RUN_DIR/invalid-public-origin.log" 2>&1; then
  fail "entrypoint accepted a public application URL with a path"
fi
grep -Fq 'CHRONICLE_PUBLIC_BASE_URL must be an exact HTTPS root origin' \
  "$RUN_DIR/invalid-public-origin.log" ||
  fail "entrypoint public-origin rejection omitted the exact validation failure"
if env -i PATH="${PATH}" \
  CHRONICLE_PUBLIC_BASE_URL=$'https://participants.example.org\n  - "https://attacker.invalid"' \
  MOBILE_SIGNING_ENABLED=false MOBILE_SIGNING_REQUIRED=false \
  MOBILE_SIGNING_SECRET='' MOBILE_SIGNING_SECRET_PREVIOUS='' \
  /bin/sh "$ENTRYPOINT" --validate-mobile-signing >/dev/null 2>&1; then
  fail "entrypoint accepted a multiline public application origin"
fi
grep -Fq '"${CHRONICLE_PUBLIC_BASE_URL}"' "$ENTRYPOINT" ||
  fail "entrypoint CORS origins omit a distinct canonical public application origin"

printf 'self-host mobile-signing defaults test passed\n'
