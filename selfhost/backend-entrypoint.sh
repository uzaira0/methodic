#!/bin/sh
# Chronicle self-host backend entrypoint.
#
# Two jobs:
#
#  1. Render ./config/*.template into real YAML with envsubst. The backend's config
#     loader reads these; the image ships an EMPTY /server/config, so without this the
#     backend has no database connection at all.
#
#  2. Launch the JVM directly instead of via the Gradle-generated ./bin/chronicle-server.
#     That script hardcodes `--add-modules java.se`, but the image's jlink-built minimal
#     JRE does not include java.se, so it dies at boot with
#     "java.lang.module.FindException: Module java.se not found". Invoking java with an
#     explicit classpath is exactly what the reference deployment does for the same reason.
#
# Defaults below mean a public-client deployment needs no shared mobile key. Public clients
# authenticate with their enrollment-issued per-device API key. envsubst turns an unset
# variable into an empty string, so boolean and numeric fields still need explicit defaults.
set -eu

: "${DOMAIN:=localhost}"
: "${CHRONICLE_PUBLIC_BASE_URL:=https://${DOMAIN}}"
: "${POSTGRES_HOST:=postgres}"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_DB:=chronicle}"
: "${POSTGRES_USER:=chronicle}"

# Hazelcast is single-node and bound to localhost inside this container; these passwords
# never cross the network. Defaulted so the stack starts without extra configuration.
: "${HAZELCAST_SERVER_PASSWORD:=chronicle-selfhost}"
: "${HAZELCAST_CLIENT_PASSWORD:=chronicle-selfhost}"

: "${MOBILE_SIGNING_ENABLED:=false}"
: "${MOBILE_SIGNING_REQUIRED:=false}"
: "${MOBILE_SIGNING_SECRET:=}"
: "${MOBILE_SIGNING_SECRET_PREVIOUS:=}"
: "${CHRONICLE_REVIEWER_ACCESS_ENABLED:=false}"
: "${CHRONICLE_REVIEWER_ACCESS_SECRET:=}"
: "${CHRONICLE_REVIEWER_STUDY_ID:=}"
: "${CHRONICLE_REVIEWER_PARTICIPANT_ID:=}"
# X-Chronicle-Internal-Web marks researcher-console traffic so MobileApiSignatureFilter lets
# it through without a mobile HMAC signature. This stack genuinely needs it: Caddy rewrites
# /chronicle/api/web/* to /chronicle/v3/*, which puts dashboard calls squarely inside the
# filter's MOBILE_API_PREFIXES ("/chronicle/v3/study/"), so an unmarked dashboard request is
# rejected as an unsigned upload.
#
# It is therefore a SHARED value, not a per-boot one: Caddy stamps it and the backend
# compares it (in constant time). Production-style self-hosting refuses the historical
# guessable literal "true" (CWE-290).

# CORS allowlist for config/cors.yaml.template. Every host an operator opens the dashboard
# on has to be here: CorsValidationFilter rejects an unlisted Origin, and the failure is
# invisible from the browser — the SPA renders in full, the header reads "awaiting-sso", and
# sign-in never completes. Listing only https://$DOMAIN left the internal-dashboard modes
# broken by construction, since there the researcher API is served *only* on the internal
# listener, whose origin is https://<host>:$INTERNAL_PORT and never equals $DOMAIN.
# INTERNAL_BIND is in the list for the same reason: `./chronicle setup` offers "your VPN or
# management interface" as the answer, and taking that offer makes the dashboard's origin
# https://<that address>:$INTERNAL_PORT. Allowing only the loopback pair assumed every
# operator reaches it through an SSH tunnel, so the offered answer produced a stack that
# started clean, verified clean, and could not be signed in to.
: "${INTERNAL_PORT:=8081}"
: "${INTERNAL_BIND:=127.0.0.1}"
: "${DASHBOARD_ORIGINS:=}"

validate_https_root_origin() {
  value="$1"
  case "$value" in
    *[[:space:]]*)
      printf 'FATAL: CHRONICLE_PUBLIC_BASE_URL must be an exact HTTPS root origin\n' >&2
      return 1
      ;;
  esac
  if ! printf '%s\n' "$value" | grep -Eq \
    '^https://(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)(:[0-9]{1,5})?$'; then
    printf 'FATAL: CHRONICLE_PUBLIC_BASE_URL must be an exact HTTPS root origin\n' >&2
    return 1
  fi
  authority="${value#https://}"
  case "$authority" in
    *]:*) port="${authority##*:}" ;;
    *:*)
      host="${authority%:*}"
      case "$host" in *:*) port="" ;; *) port="${authority##*:}" ;; esac
      ;;
    *) port="" ;;
  esac
  if [ -n "$port" ] && { [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; }; then
    printf 'FATAL: CHRONICLE_PUBLIC_BASE_URL must be an exact HTTPS root origin\n' >&2
    return 1
  fi
}

validate_https_root_origin "$CHRONICLE_PUBLIC_BASE_URL"
CORS_ALLOWED_ORIGINS_YAML=$(
  for origin in \
    "https://${DOMAIN}" \
    "${CHRONICLE_PUBLIC_BASE_URL}" \
    "https://127.0.0.1:${INTERNAL_PORT}" \
    "https://localhost:${INTERNAL_PORT}" \
    "https://${INTERNAL_BIND}:${INTERNAL_PORT}" \
    "https://${DOMAIN}:${INTERNAL_PORT}" \
    ${DASHBOARD_ORIGINS}; do
    [ -n "$origin" ] && printf '  - "%s"\n' "$origin"
  done | awk '!seen[$0]++'
)
export CORS_ALLOWED_ORIGINS_YAML

: "${TESTING_LOGIN_ENABLED:=false}"
: "${ALLOW_PRODUCTION_TESTING_LOGIN:=false}"
: "${DASHBOARD_PASSWORD_HASH:=}"

: "${OIDC_ENABLED:=false}"
: "${OIDC_PROVIDER_LABEL:=}"
: "${OIDC_PUBLIC_BASE_URL:=}"
: "${OIDC_ISSUER:=}"
: "${OIDC_AUTHORIZATION_URI:=}"
: "${OIDC_TOKEN_URI:=}"
: "${OIDC_JWKS_URI:=}"
: "${OIDC_CLIENT_ID:=}"
: "${OIDC_CLIENT_SECRET:=}"
: "${OIDC_IDP_HINT:=}"
: "${OIDC_COOKIE_TOKEN_CLAIM:=}"

: "${SMTP_ENABLED:=false}"
: "${SMTP_HOST:=}"
: "${SMTP_PORT:=587}"
: "${SMTP_USERNAME:=}"
: "${SMTP_PASSWORD:=}"
: "${SMTP_FROM_EMAIL:=}"

: "${VAULT_ENABLED:=false}"
: "${VAULT_ADDR:=}"
: "${VAULT_TOKEN:=}"

: "${CHRONICLE_SERVER_XMS:=-Xms512m}"
: "${CHRONICLE_SERVER_XMX:=-Xmx2g}"
: "${CHRONICLE_SERVER_ARGS:=local postgres medialocal}"

mobile_signing_fatal() {
  printf 'FATAL: %s\n' "$1" >&2
  return 1
}

validate_mobile_signing() {
  case "$MOBILE_SIGNING_ENABLED" in
    true|false) ;;
    *) mobile_signing_fatal "MOBILE_SIGNING_ENABLED must be exactly true or false" || return 1 ;;
  esac
  case "$MOBILE_SIGNING_REQUIRED" in
    true|false) ;;
    *) mobile_signing_fatal "MOBILE_SIGNING_REQUIRED must be exactly true or false" || return 1 ;;
  esac

  if [ "$MOBILE_SIGNING_ENABLED" != "$MOBILE_SIGNING_REQUIRED" ]; then
    mobile_signing_fatal \
      "MOBILE_SIGNING_ENABLED and MOBILE_SIGNING_REQUIRED must either both be true or both be false" || return 1
  fi

  if [ "$MOBILE_SIGNING_ENABLED" = false ]; then
    if [ -n "$MOBILE_SIGNING_SECRET" ]; then
      mobile_signing_fatal \
        "MOBILE_SIGNING_SECRET must stay blank unless controlled legacy compatibility is enabled" || return 1
    fi
    if [ -n "$MOBILE_SIGNING_SECRET_PREVIOUS" ]; then
      mobile_signing_fatal \
        "MOBILE_SIGNING_SECRET_PREVIOUS must stay blank unless controlled legacy compatibility is enabled" || return 1
    fi
    return 0
  fi

  case "$MOBILE_SIGNING_SECRET" in
    *CHANGE_ME*|'')
      mobile_signing_fatal \
        "MOBILE_SIGNING_SECRET must be a generated 32+ character key when controlled legacy compatibility is enabled" || return 1
      ;;
  esac
  if [ "${#MOBILE_SIGNING_SECRET}" -lt 32 ]; then
    mobile_signing_fatal \
      "MOBILE_SIGNING_SECRET must be a generated 32+ character key when controlled legacy compatibility is enabled" || return 1
  fi
  if [ -n "$MOBILE_SIGNING_SECRET_PREVIOUS" ]; then
    if [ "${#MOBILE_SIGNING_SECRET_PREVIOUS}" -lt 32 ]; then
      mobile_signing_fatal "MOBILE_SIGNING_SECRET_PREVIOUS must be at least 32 characters" || return 1
    fi
    if [ "$MOBILE_SIGNING_SECRET_PREVIOUS" = "$MOBILE_SIGNING_SECRET" ]; then
      mobile_signing_fatal "MOBILE_SIGNING_SECRET_PREVIOUS must differ from MOBILE_SIGNING_SECRET" || return 1
    fi
  fi
}

validate_mobile_signing
if [ "${1:-}" = --validate-mobile-signing ]; then
  [ "$#" -eq 1 ] || mobile_signing_fatal "--validate-mobile-signing accepts no additional arguments"
  exit 0
fi

export DOMAIN POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD \
  CHRONICLE_PUBLIC_BASE_URL \
  HAZELCAST_SERVER_PASSWORD HAZELCAST_CLIENT_PASSWORD JWT_SECRET \
  MOBILE_SIGNING_ENABLED MOBILE_SIGNING_REQUIRED MOBILE_SIGNING_SECRET \
  MOBILE_SIGNING_SECRET_PREVIOUS \
  CHRONICLE_REVIEWER_ACCESS_ENABLED CHRONICLE_REVIEWER_ACCESS_SECRET \
  CHRONICLE_REVIEWER_STUDY_ID CHRONICLE_REVIEWER_PARTICIPANT_ID \
  CHRONICLE_INTERNAL_WEB_SECRET TESTING_LOGIN_ENABLED ALLOW_PRODUCTION_TESTING_LOGIN \
  DASHBOARD_PASSWORD_HASH \
  OIDC_ENABLED OIDC_PROVIDER_LABEL OIDC_PUBLIC_BASE_URL OIDC_ISSUER \
  OIDC_AUTHORIZATION_URI OIDC_TOKEN_URI OIDC_JWKS_URI OIDC_CLIENT_ID OIDC_CLIENT_SECRET \
  OIDC_IDP_HINT OIDC_COOKIE_TOKEN_CLAIM \
  SMTP_ENABLED SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_FROM_EMAIL \
  VAULT_ENABLED VAULT_ADDR VAULT_TOKEN

for required in POSTGRES_PASSWORD JWT_SECRET CHRONICLE_INTERNAL_WEB_SECRET; do
  eval "value=\${$required:-}"
  if [ -z "$value" ]; then
    echo "FATAL: $required is not set — see selfhost/.env.example" >&2
    exit 1
  fi
done

# The AUDIT logger in log4j2.xml writes ONLY to a file under this directory
# (additivity="false"). If it is missing or read-only, the file half of the audit trail --
# the SIEM-facing copy, and the one that outlives the database -- is lost, and nothing
# notices: the backend serves traffic, the health check passes, and ./chronicle verify
# reports a healthy deployment. Refuse to start instead, the same way the production stack
# does.
AUDIT_DIR="${AUDIT_LOG_DIR:-/var/log/chronicle}"
if [ ! -d "$AUDIT_DIR" ]; then
  echo "FATAL: $AUDIT_DIR not mounted (audit logs required)" >&2
  exit 1
fi
if ! touch "$AUDIT_DIR/.write-probe" 2>/dev/null; then
  echo "FATAL: $AUDIT_DIR is not writable by $(id -un) (audit logs required)" >&2
  exit 1
fi
rm -f "$AUDIT_DIR/.write-probe"

RENDERED=/server/rendered-config
mkdir -p "$RENDERED"

for name in rhizome chronicle-auth mail mobile-security vault cors; do
  src="/server/config/${name}.yaml.template"
  dst="${RENDERED}/${name}.yaml"
  if [ ! -f "$src" ]; then
    echo "FATAL: missing config template $src" >&2
    exit 1
  fi
  envsubst < "$src" > "$dst"
  if [ ! -s "$dst" ]; then
    echo "FATAL: $dst is empty after rendering" >&2
    exit 1
  fi
  # An unresolved ${VAR} means a variable this script does not know about was added to a
  # template. Fail loudly rather than hand the backend YAML it will misparse.
  # shellcheck disable=SC2016  # the literal ${ is intentional, not an expansion
  if grep -q '\${' "$dst"; then
    echo "FATAL: $dst still contains unresolved template variables" >&2
    # shellcheck disable=SC2016
    grep -n '\${' "$dst" >&2
    exit 1
  fi
done

echo "Rendered config into ${RENDERED}:"
find "$RENDERED" -maxdepth 1 -type f -name '*.yaml' -exec basename {} \; | sort | sed 's/^/  /'

# shellcheck disable=SC2086
exec java $CHRONICLE_SERVER_XMS $CHRONICLE_SERVER_XMX \
  -Xss512k -XX:MetaspaceSize=128m -XX:MaxMetaspaceSize=256m \
  -XX:+UseStringDeduplication -XX:MaxGCPauseMillis=200 \
  -Dlog4j2.formatMsgNoLookups=true \
  -Djava.io.tmpdir=/server/scratch \
  -cp "${RENDERED}:/server/lib/*" \
  com.openlattice.chronicle.ChronicleServer $CHRONICLE_SERVER_ARGS
