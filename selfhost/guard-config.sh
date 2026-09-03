#!/usr/bin/env bash
# The configuration checks that used to live in `./chronicle check`, moved into a one-shot
# compose service so that `docker compose up -d` cannot start an unsafe deployment. Every
# other service in the stack waits for this one to exit 0.
#
# Only checks that can be answered from configuration alone are here. Three of the checks in
# `./chronicle check` genuinely cannot move, because a container has its own network
# namespace and its own view of the filesystem:
#
#   * whether HTTP_BIND/INTERNAL_BIND is an address this host actually has
#   * whether HTTP_PORT/INTERNAL_PORT is already in use by another process
#   * whether a foreign Compose project of the same name would be adopted
#
# Those stay in `./chronicle check`. On the plain-compose path Docker's own bind error is
# the fallback for the first two, which is later and less clear but not silent.
#
# TLS_MODE and DASHBOARD_EXPOSURE are NOT read from .env here. They are set on this service
# by the mode overlay in COMPOSE_FILE, so what is checked is the overlay that was actually
# composed in -- not a variable that could disagree with it. Composing no mode overlay at
# all leaves them empty and fails below, which is the correct answer for a stack whose web
# listener would publish nothing.
set -uo pipefail

parse_public_authority() {
  local authority="$1" port=""
  PUBLIC_HOST=""
  [[ -n "$authority" ]] || return 1
  case "$authority" in
    *[[:space:]]*|*/*|*\?*|*\#*|*@*) return 1 ;;
  esac

  if [[ "$authority" =~ ^\[([0-9A-Fa-f:]+)\](:([0-9]+))?$ ]]; then
    PUBLIC_HOST="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]:-}"
  elif [[ "$authority" =~ ^([A-Za-z0-9.-]+)(:([0-9]+))?$ ]]; then
    PUBLIC_HOST="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]:-}"
  else
    return 1
  fi

  if [[ -n "$port" ]]; then
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    ((10#$port >= 1 && 10#$port <= 65535)) || return 1
  fi
  return 0
}

is_valid_ipv4_literal() {
  local host="$1" octet numeric
  local -a octets
  [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$host"
  for octet in "${octets[@]}"; do
    numeric=$((10#$octet))
    ((numeric <= 255)) || return 1
  done
}

is_non_global_ipv4_literal() {
  local host="$1" a b c d
  is_valid_ipv4_literal "$host" || return 1
  IFS=. read -r a b c d <<< "$host"
  a=$((10#$a)); b=$((10#$b)); c=$((10#$c)); d=$((10#$d))

  ((a == 0 || a == 10 || a == 127 || a >= 224)) && return 0
  ((a == 100 && b >= 64 && b <= 127)) && return 0
  ((a == 169 && b == 254)) && return 0
  ((a == 172 && b >= 16 && b <= 31)) && return 0
  ((a == 192 && b == 0 && c == 0)) && return 0
  ((a == 192 && b == 0 && c == 2)) && return 0
  ((a == 192 && b == 88 && c == 99)) && return 0
  ((a == 192 && b == 168)) && return 0
  ((a == 198 && (b == 18 || b == 19))) && return 0
  ((a == 198 && b == 51 && c == 100)) && return 0
  ((a == 203 && b == 0 && c == 113)) && return 0
  return 1
}

is_non_global_ipv6_literal() {
  local host="${1,,}" first_hextet first_value
  [[ "$host" == *:* ]] || return 1
  case "$host" in
    ::|::1|::ffff:*|2001:db8:*|ff*) return 0 ;;
  esac
  first_hextet="${host%%:*}"
  [[ "$first_hextet" =~ ^[0-9a-f]{1,4}$ ]] || return 0
  first_value=$((16#$first_hextet))
  ((first_value >= 0xfc00 && first_value <= 0xfdff)) && return 0
  ((first_value >= 0xfe80 && first_value <= 0xfebf)) && return 0
  return 1
}

is_valid_ipv6_literal() {
  local host="${1,,}" left right piece
  local -a pieces=()
  local count=0
  [[ "$host" == *:* && "$host" != *[^0-9a-f:]* && "$host" != *:::* ]] || return 1

  if [[ "$host" == *::* ]]; then
    left="${host%%::*}"
    right="${host#*::}"
    [[ "$right" != *::* ]] || return 1
    if [[ -n "$left" ]]; then
      IFS=: read -r -a pieces <<< "$left"
      for piece in "${pieces[@]}"; do
        [[ "$piece" =~ ^[0-9a-f]{1,4}$ ]] || return 1
        count=$((count + 1))
      done
    fi
    if [[ -n "$right" ]]; then
      IFS=: read -r -a pieces <<< "$right"
      for piece in "${pieces[@]}"; do
        [[ "$piece" =~ ^[0-9a-f]{1,4}$ ]] || return 1
        count=$((count + 1))
      done
    fi
    ((count < 8)) || return 1
  else
    [[ "$host" != :* && "$host" != *: ]] || return 1
    IFS=: read -r -a pieces <<< "$host"
    ((${#pieces[@]} == 8)) || return 1
    for piece in "${pieces[@]}"; do
      [[ "$piece" =~ ^[0-9a-f]{1,4}$ ]] || return 1
    done
  fi
}

is_valid_public_dns_name() {
  local host="${1,,}" label
  local -a labels
  [[ ${#host} -le 253 && "$host" == *.* && "$host" != .* && "$host" != *. ]] || return 1
  [[ "$host" =~ ^[a-z0-9.-]+$ ]] || return 1
  IFS=. read -r -a labels <<< "$host"
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
  case "$host" in
    localhost|*.localhost|local|*.local|invalid|*.invalid|test|*.test) return 1 ;;
  esac
  return 0
}

public_host_is_allowed() {
  local host="$1" normalized
  [[ -n "$host" ]] || return 1
  normalized="${host,,}"
  normalized="${normalized%.}"
  if [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    is_valid_ipv4_literal "$host" || return 1
    is_non_global_ipv4_literal "$host" && return 1
  elif [[ "$host" == *:* ]]; then
    is_valid_ipv6_literal "$host" || return 1
    is_non_global_ipv6_literal "$host" && return 1
  else
    is_valid_public_dns_name "$normalized" || return 1
  fi
  return 0
}

public_deployment_host_is_allowed() {
  parse_public_authority "$1" || return 1
  public_host_is_allowed "$PUBLIC_HOST"
}

public_root_https_origin_is_allowed() {
  local value="$1" authority
  [[ "$value" == https://* ]] || return 1
  authority="${value#https://}"
  [[ -n "$authority" && "$authority" != "$value" ]] || return 1
  parse_public_authority "$authority" || return 1
  public_host_is_allowed "$PUBLIC_HOST"
}

# A narrow diagnostic mode lets verify-config.sh exercise the exact classifier used at
# startup without reconstructing an otherwise complete deployment environment.
if [[ "${1:-}" == --validate-public-host ]]; then
  [[ $# -eq 2 ]] || exit 2
  public_deployment_host_is_allowed "$2" && exit 0
  exit 1
fi
if [[ "${1:-}" == --validate-public-origin ]]; then
  [[ $# -eq 2 ]] || exit 2
  public_root_https_origin_is_allowed "$2" && exit 0
  exit 1
fi

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
FAILED=0
ok()   { printf '  %sok%s   %s\n' "$GRN" "$RST" "$1"; }
bad()  { printf '  %sFAIL%s %s\n' "$RED" "$RST" "$1"; FAILED=1; }
warn() { printf '  %swarn%s %s\n' "$YEL" "$RST" "$1"; }

: "${TLS_MODE:=}"
: "${DASHBOARD_EXPOSURE:=}"
: "${COMPOSE_FILE_SELECTION:=}"
: "${BACKUPS_ENABLED:=false}"
: "${AUTH_OVERLAY_ENABLED:=false}"
: "${MONITORING_ENABLED:=false}"
: "${GRAFANA_ADMIN_PASSWORD:=}"
: "${GRAFANA_BIND:=127.0.0.1}"
: "${GRAFANA_PORT:=3000}"
: "${METRICS_RETENTION:=30d}"
: "${LOGS_RETENTION:=14d}"
: "${METRICS_MAX_DISK_BYTES:=5368709120}"
: "${LOGS_MAX_DISK_BYTES:=5368709120}"
: "${METRICS_MIN_FREE_DISK_BYTES:=2147483648}"
: "${FLUENT_BIT_FORWARD_PORT:=24224}"
: "${CHRONICLE_INTERNAL_WEB_SECRET:=}"
: "${MOBILE_SIGNING_ENABLED:=false}"
: "${MOBILE_SIGNING_REQUIRED:=false}"
: "${MOBILE_SIGNING_SECRET:=}"
: "${MOBILE_SIGNING_SECRET_PREVIOUS:=}"
: "${CHRONICLE_REVIEWER_ACCESS_ENABLED:=false}"
: "${CHRONICLE_REVIEWER_ACCESS_SECRET:=}"
: "${CHRONICLE_REVIEWER_STUDY_ID:=}"
: "${CHRONICLE_REVIEWER_PARTICIPANT_ID:=}"
: "${ENABLE_ENCRYPTION:=true}"
: "${TESTING_LOGIN_ENABLED:=false}"
: "${REQUIRE_MFA:=true}"
: "${HTTP_BIND:=127.0.0.1}"
: "${INTERNAL_BIND:=127.0.0.1}"
: "${INTERNAL_PORT:=8081}"
: "${DASHBOARD_PASSWORD_HASH:=}"
: "${DASHBOARD_ALLOWED_IPS:=}"
: "${RELEASE_VERSION:=development}"
: "${CHRONICLE_PUBLIC_BASE_URL:=}"

write_configuration_metric() {
  [[ -d /monitoring-metrics && -w /monitoring-metrics ]] || return 0
  local valid="$1" temporary="/monitoring-metrics/.configuration.prom.$$"
  local safe_tls safe_exposure safe_release
  safe_tls="${TLS_MODE//[^A-Za-z0-9_-]/_}"
  safe_exposure="${DASHBOARD_EXPOSURE//[^A-Za-z0-9_-]/_}"
  safe_release="${RELEASE_VERSION//[^A-Za-z0-9_.-]/_}"
  umask 077
  cat >"$temporary" <<EOF
# HELP chronicle_configuration_valid Latest configuration guard result.
# TYPE chronicle_configuration_valid gauge
chronicle_configuration_valid ${valid}
# HELP chronicle_configuration_check_timestamp_seconds Latest configuration guard run.
# TYPE chronicle_configuration_check_timestamp_seconds gauge
chronicle_configuration_check_timestamp_seconds $(date +%s)
# HELP chronicle_configuration_info Non-secret deployment configuration observed by the guard.
# TYPE chronicle_configuration_info gauge
chronicle_configuration_info{tls_mode="${safe_tls}",dashboard_exposure="${safe_exposure}",monitoring="${MONITORING_ENABLED}",version="${safe_release}"} 1
EOF
  chmod 0644 "$temporary"
  mv -f "$temporary" /monitoring-metrics/configuration.prom
}

printf '%sChecking configuration%s\n' "$BLD" "$RST"

# ------------------------------------------------------------------ deployment mode
compose_base_count=0
compose_mode_count=0
compose_seen=$'\n'
if [[ -z "$COMPOSE_FILE_SELECTION" ]]; then
  bad "COMPOSE_FILE is empty — the supported deployment shape cannot be verified"
else
  IFS=: read -r -a compose_files <<< "$COMPOSE_FILE_SELECTION"
  for compose_path in "${compose_files[@]}"; do
    if [[ -z "$compose_path" ]]; then
      bad "COMPOSE_FILE contains an empty path"
      continue
    fi
    case "$compose_seen" in
      *$'\n'"${compose_path}"$'\n'*)
        bad "COMPOSE_FILE contains the same file twice: ${compose_path}"
        continue
        ;;
    esac
    compose_seen+="${compose_path}"$'\n'
    case "$compose_path" in
      docker-compose.yml|*/docker-compose.yml)
        compose_base_count=$((compose_base_count + 1)) ;;
      overlays/mode-behind-proxy-internal.yml|*/overlays/mode-behind-proxy-internal.yml|\
      overlays/mode-own-tls-internal.yml|*/overlays/mode-own-tls-internal.yml|\
      overlays/mode-local-https.yml|*/overlays/mode-local-https.yml|\
      experimental/public-dashboard/mode-behind-proxy-public.yml|*/experimental/public-dashboard/mode-behind-proxy-public.yml|\
      experimental/public-dashboard/mode-own-tls-public.yml|*/experimental/public-dashboard/mode-own-tls-public.yml)
        compose_mode_count=$((compose_mode_count + 1)) ;;
      overlays/backups.yml|*/overlays/backups.yml|\
      overlays/monitoring.yml|*/overlays/monitoring.yml|\
      experimental/public-dashboard/auth.yml|*/experimental/public-dashboard/auth.yml)
        ;;
      *) bad "unsupported file in COMPOSE_FILE: ${compose_path}" ;;
    esac
  done
  [[ $compose_base_count -eq 1 ]] ||
    bad "COMPOSE_FILE must contain docker-compose.yml exactly once (found ${compose_base_count})"
  [[ $compose_mode_count -eq 1 ]] ||
    bad "COMPOSE_FILE must contain exactly one mode overlay (found ${compose_mode_count})"
fi

if [[ -z "$TLS_MODE" || -z "$DASHBOARD_EXPOSURE" ]]; then
  bad "no deployment mode selected — COMPOSE_FILE has no overlays/mode-*.yml in it."
  printf '       The web listener would publish no ports at all. Copy the COMPOSE_FILE line\n'
  printf '       from .env.example, or pick one of:\n'
  printf '         overlays/mode-behind-proxy-internal.yml   (recommended)\n'
  printf '         overlays/mode-own-tls-internal.yml\n'
  printf '         overlays/mode-local-https.yml             (laptop trial, no domain)\n'
else
  case "${TLS_MODE}/${DASHBOARD_EXPOSURE}" in
    local-https/internal)
      ok "deployment mode: local trial (Caddy's own CA, no domain name needed)"
      warn "This is a TRIAL mode. The certificate is signed by a CA that exists only inside this stack, so every device must install it first — fine for your own test phones, wrong for participants. Move to mode-behind-proxy-internal or mode-own-tls-internal for a real study." ;;
    behind-proxy/internal|own-tls/internal)
      ok "deployment mode: TLS_MODE=${TLS_MODE}, DASHBOARD_EXPOSURE=${DASHBOARD_EXPOSURE}" ;;
    behind-proxy/public|own-tls/public)
      warn "public-dashboard mode is experimental and is not shipped in release bundles" ;;
    *)
      bad "unrecognised mode overlay (TLS_MODE='${TLS_MODE}', DASHBOARD_EXPOSURE='${DASHBOARD_EXPOSURE}')" ;;
  esac
fi

# A misspelled boolean must not silently turn off encryption, backups, authentication, or
# MFA. Compose passes these values as strings, so validate the contract before branching.
for flag in BACKUPS_ENABLED AUTH_OVERLAY_ENABLED MONITORING_ENABLED ENABLE_ENCRYPTION \
            TESTING_LOGIN_ENABLED REQUIRE_MFA CHRONICLE_REVIEWER_ACCESS_ENABLED \
            MOBILE_SIGNING_ENABLED MOBILE_SIGNING_REQUIRED; do
  case "${!flag}" in
    true|false) ;;
    *) bad "${flag} must be exactly true or false (received '${!flag}')" ;;
  esac
done

# ------------------------------------------------------------------ secrets
# Placeholder detection has to be separate from the length check: the shipped placeholders
# are long enough to pass a length test and would otherwise sail through.
placeholders=""
for k in DOMAIN POSTGRES_PASSWORD CHRONICLE_INTERNAL_WEB_SECRET JWT_SECRET METRICS_PASSWORD; do
  case "${!k:-}" in
    *CHANGE_ME*|*chronicle.example*|"") placeholders="${placeholders}${k} " ;;
  esac
done
if [[ "$MONITORING_ENABLED" == true ]]; then
  case "$GRAFANA_ADMIN_PASSWORD" in
    *CHANGE_ME*|*changeme*|admin|"") placeholders="${placeholders}GRAFANA_ADMIN_PASSWORD " ;;
  esac
fi
if [[ -n "${placeholders// }" ]]; then
  bad "still at placeholder/empty values: ${placeholders}"
  printf '       Edit .env — these are the values only you can supply.\n'
else
  ok "every value this deployment uses has been set"
fi

# In every other mode DOMAIN is a name someone else resolves. Here it is the address the
# phones dial directly, so `localhost` is not merely unusual -- it is unreachable from any
# device but this one, and Caddy cannot issue a LAN certificate for it either.
if [[ "$TLS_MODE" == local-https ]]; then
  local_https_port="${LOCAL_HTTPS_PORT:-443}"
  local_http_port="${LOCAL_HTTP_PORT:-80}"
  case "$local_https_port" in
    ''|*[!0-9]*) bad "LOCAL_HTTPS_PORT must be a numeric TCP port" ;;
    *) ((local_https_port >= 1 && local_https_port <= 65535)) || bad "LOCAL_HTTPS_PORT must be between 1 and 65535" ;;
  esac
  case "$local_http_port" in
    ''|*[!0-9]*) bad "LOCAL_HTTP_PORT must be a numeric TCP port" ;;
    *) ((local_http_port >= 1 && local_http_port <= 65535)) || bad "LOCAL_HTTP_PORT must be between 1 and 65535" ;;
  esac
  [[ "$local_http_port" != "$local_https_port" ]] ||
    bad "LOCAL_HTTP_PORT and LOCAL_HTTPS_PORT must be different"
  case "$DOMAIN" in
    localhost|127.*|0.0.0.0|"")
      bad "DOMAIN=${DOMAIN:-<empty>} cannot be reached by a phone."
      printf '       In this mode DOMAIN is the address the phones dial. Set it to this\n'
      printf '       machine'"'"'s address on the wifi, e.g. DOMAIN=192.168.1.50.\n' ;;
    *)
      local_trial_origin="https://${DOMAIN}"
      [[ "$local_https_port" == 443 ]] || local_trial_origin+=":${local_https_port}"
      if [[ -n "$CHRONICLE_PUBLIC_BASE_URL" && "$CHRONICLE_PUBLIC_BASE_URL" != "$local_trial_origin" ]]; then
        bad "local trial CHRONICLE_PUBLIC_BASE_URL must be empty or exactly ${local_trial_origin}"
      else
        ok "phones will reach this stack at ${local_trial_origin}"
      fi
      ;;
  esac
else
  if ! public_deployment_host_is_allowed "$DOMAIN"; then
    bad "DOMAIN must be a public DNS name or globally routable IP address in production modes"
  fi
  effective_public_base_url="${CHRONICLE_PUBLIC_BASE_URL:-https://${DOMAIN}}"
  if ! public_root_https_origin_is_allowed "$effective_public_base_url"; then
    bad "CHRONICLE_PUBLIC_BASE_URL must be an HTTPS root origin with a public DNS name or globally routable IP address"
  fi
fi

for s in POSTGRES_PASSWORD CHRONICLE_INTERNAL_WEB_SECRET; do
  v="${!s:-}"
  if [[ -z "$v" ]]; then bad "$s is not set"
  elif [[ ${#v} -lt 16 ]]; then bad "$s is only ${#v} characters; use at least 16"
  fi
done

# Public clients use per-device API keys, so the shared HMAC compatibility mode is a strict,
# explicit opt-in. Treat the two booleans and both key slots as one atomic configuration:
# accepting a partial state would either weaken a legacy fleet silently or retain an unused
# deployment-wide credential indefinitely.
if [[ "$MOBILE_SIGNING_ENABLED" != "$MOBILE_SIGNING_REQUIRED" ]]; then
  bad "MOBILE_SIGNING_ENABLED and MOBILE_SIGNING_REQUIRED must either both be true or both be false"
elif [[ "$MOBILE_SIGNING_ENABLED" == false ]]; then
  if [[ -n "$MOBILE_SIGNING_SECRET" ]]; then
    bad "MOBILE_SIGNING_SECRET must stay blank unless controlled legacy compatibility is enabled"
  fi
  if [[ -n "$MOBILE_SIGNING_SECRET_PREVIOUS" ]]; then
    bad "MOBILE_SIGNING_SECRET_PREVIOUS must stay blank unless controlled legacy compatibility is enabled"
  fi
  if [[ -z "$MOBILE_SIGNING_SECRET" && -z "$MOBILE_SIGNING_SECRET_PREVIOUS" ]]; then
    ok "public mobile clients use per-device API keys; legacy shared-HMAC compatibility is off"
  fi
elif [[ "$MOBILE_SIGNING_ENABLED" == true ]]; then
  case "$MOBILE_SIGNING_SECRET" in
    *CHANGE_ME*|'')
      bad "MOBILE_SIGNING_SECRET must be a generated 32+ character key when controlled legacy compatibility is enabled"
      ;;
    *)
      if [[ ${#MOBILE_SIGNING_SECRET} -lt 32 ]]; then
        bad "MOBILE_SIGNING_SECRET must be a generated 32+ character key when controlled legacy compatibility is enabled"
      fi
      ;;
  esac
  if [[ -n "$MOBILE_SIGNING_SECRET_PREVIOUS" ]]; then
    if [[ ${#MOBILE_SIGNING_SECRET_PREVIOUS} -lt 32 ]]; then
      bad "MOBILE_SIGNING_SECRET_PREVIOUS is only ${#MOBILE_SIGNING_SECRET_PREVIOUS} characters; a rotation overlap key needs at least 32"
    elif [[ "$MOBILE_SIGNING_SECRET_PREVIOUS" == "$MOBILE_SIGNING_SECRET" ]]; then
      bad "MOBILE_SIGNING_SECRET_PREVIOUS equals MOBILE_SIGNING_SECRET; remove the redundant overlap key"
    else
      warn "controlled legacy mobile signing-key rotation overlap is active; finalize it after every supported legacy client has moved to the current key"
    fi
  fi
  [[ $FAILED -ne 0 ]] || warn "controlled legacy shared-HMAC compatibility is enabled; public clients still use per-device API keys"
fi

# 32, not 16, and it is a hard requirement rather than advice: JWT_SECRET is an HS256
# signing key, and Spring's NimbusJwtDecoder rejects anything under 256 bits outright with
# "The secret length must be at least 256 bits". Nothing about that is visible at startup --
# the backend boots, reports healthy, and serves the dashboard. The failure appears only
# when someone logs in, as HTTP 500 "configured testing token is invalid", which reads as a
# broken build rather than a short string in .env. A hand-typed passphrase lands under 32
# characters very easily; `openssl rand -base64 32` gives 44.
v="${JWT_SECRET:-}"
if [[ -z "$v" ]]; then
  bad "JWT_SECRET is not set"
elif [[ ${#v} -lt 32 ]]; then
  bad "JWT_SECRET is only ${#v} characters; HS256 needs at least 32 (256 bits)"
  printf '       Below that, the dashboard signs in and fails with 500 "configured testing\n'
  printf '       token is invalid". Generate one: openssl rand -base64 32\n'
fi
if [[ ${#CHRONICLE_INTERNAL_WEB_SECRET} -lt 32 ]]; then
  bad "CHRONICLE_INTERNAL_WEB_SECRET is ${#CHRONICLE_INTERNAL_WEB_SECRET} characters; use at least 32"
fi
if [[ "$CHRONICLE_REVIEWER_ACCESS_ENABLED" == true ]]; then
  case "$CHRONICLE_REVIEWER_ACCESS_SECRET" in
    *CHANGE_ME*|"")
      bad "CHRONICLE_REVIEWER_ACCESS_SECRET must be a generated 32+ character secret when reviewer access is enabled" ;;
    *)
      if [[ ${#CHRONICLE_REVIEWER_ACCESS_SECRET} -lt 32 || ${#CHRONICLE_REVIEWER_ACCESS_SECRET} -gt 256 ]]; then
        bad "CHRONICLE_REVIEWER_ACCESS_SECRET must be 32-256 characters"
      elif [[ "$CHRONICLE_REVIEWER_ACCESS_SECRET" =~ [[:space:]] ]]; then
        bad "CHRONICLE_REVIEWER_ACCESS_SECRET must not contain whitespace"
      fi ;;
  esac
  if [[ ! "$CHRONICLE_REVIEWER_STUDY_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    bad "CHRONICLE_REVIEWER_STUDY_ID must be the UUID of the synthetic reviewer study"
  fi
  if [[ ! "$CHRONICLE_REVIEWER_PARTICIPANT_ID" =~ ^[a-zA-Z0-9_.-]{1,255}$ ]]; then
    bad "CHRONICLE_REVIEWER_PARTICIPANT_ID must be a non-PII Chronicle participant ID"
  fi
else
  ok "Google Play reviewer bootstrap is disabled"
fi
# The backend hard-fails at startup below 32 (MetricsAuthenticationFilter), so catch it
# here rather than in a crash loop that looks like a broken image.
if [[ ${#METRICS_PASSWORD} -lt 32 ]]; then
  bad "METRICS_PASSWORD is ${#METRICS_PASSWORD} characters; the backend refuses to start below 32"
fi
[[ $FAILED -eq 0 ]] && ok "secrets are set and long enough"

if [[ "$MONITORING_ENABLED" == true ]]; then
  if [[ ${#GRAFANA_ADMIN_PASSWORD} -lt 32 ]]; then
    bad "GRAFANA_ADMIN_PASSWORD is ${#GRAFANA_ADMIN_PASSWORD} characters; use at least 32"
  fi
  if [[ "$GRAFANA_BIND" == "0.0.0.0" || "$GRAFANA_BIND" == "::" || "$GRAFANA_BIND" == "[::]" ]]; then
    bad "GRAFANA_BIND=${GRAFANA_BIND} exposes the monitoring dashboard on every interface"
    printf '       Keep it on 127.0.0.1 and use an SSH tunnel, or bind one reviewed private address.\n'
  fi
  if [[ ! "$GRAFANA_PORT" =~ ^[1-9][0-9]*$ ]] || (( GRAFANA_PORT > 65535 )); then
    bad "GRAFANA_PORT must be an integer from 1 through 65535"
  fi
  if [[ ! "$FLUENT_BIT_FORWARD_PORT" =~ ^[1-9][0-9]*$ ]] || (( FLUENT_BIT_FORWARD_PORT > 65535 )); then
    bad "FLUENT_BIT_FORWARD_PORT must be an integer from 1 through 65535"
  fi
  [[ "$METRICS_RETENTION" =~ ^[1-9][0-9]*d$ ]] || bad "METRICS_RETENTION must be whole days, for example 30d"
  [[ "$LOGS_RETENTION" =~ ^[1-9][0-9]*d$ ]] || bad "LOGS_RETENTION must be whole days, for example 14d"
  for budget in METRICS_MAX_DISK_BYTES LOGS_MAX_DISK_BYTES METRICS_MIN_FREE_DISK_BYTES; do
    if [[ ! "${!budget}" =~ ^[1-9][0-9]*$ ]] || (( ${!budget} < 268435456 )); then
      bad "${budget} must be an integer of at least 268435456 bytes (256 MiB)"
    fi
  done
  if [[ $FAILED -eq 0 ]]; then
    ok "optional monitoring is private, bounded, and uses a non-default Grafana credential"
  fi
fi

# ------------------------------------------------------------------ encryption / backups
# Encryption without backups is a trap, not a safeguard. Losing the keyring makes the data
# volume permanently unreadable -- pg_dump cannot rescue it either -- and the only key-free
# copy of the data is the plain-SQL dumps the backups overlay writes.
if [[ "$TLS_MODE" != local-https && -n "$TLS_MODE" && "$BACKUPS_ENABLED" != true ]]; then
  bad "production deployment modes require overlays/backups.yml in COMPOSE_FILE."
  printf '       A production install without a recoverable dump is not a supported Chronicle\n'
  printf '       configuration. Add the backups overlay. Only local-https trial mode may run\n'
  printf '       without it, and only when ENABLE_ENCRYPTION=false.\n'
elif [[ "$ENABLE_ENCRYPTION" == true && "$BACKUPS_ENABLED" != true ]]; then
  bad "encryption at rest is on, but overlays/backups.yml is not in COMPOSE_FILE."
  printf '       Encrypted data is unrecoverable if the keyring is lost; the plain-SQL dumps\n'
  printf '       in ./backups are the only copy that needs no key. Add the backups overlay,\n'
  printf '       or set ENABLE_ENCRYPTION=false to run without encryption at rest.\n'
elif [[ "$ENABLE_ENCRYPTION" == true ]]; then
  ok "encryption at rest on, with key-free SQL dumps in ./backups"
else
  warn "encryption at rest is OFF (ENABLE_ENCRYPTION=false)"
fi

# ------------------------------------------------------------------ dashboard login
# testing-login mints an admin session; it is only defensible when the auth endpoints are
# off the public listener.
if [[ "$TESTING_LOGIN_ENABLED" == true && "$DASHBOARD_EXPOSURE" != internal ]]; then
  bad "TESTING_LOGIN_ENABLED=true with DASHBOARD_EXPOSURE=${DASHBOARD_EXPOSURE}"
  printf '       That publishes admin-session minting at /chronicle/v3/auth/testing-login.\n'
  printf '       Use a supported mode-*-internal overlay.\n'
elif [[ "$DASHBOARD_EXPOSURE" == public && "$AUTH_OVERLAY_ENABLED" != true ]]; then
  bad "a public dashboard requires a separately reviewed authentication overlay"
  printf '       The supported release ships only internal-dashboard modes and no SSO provider.\n'
  printf '       Use a supported mode-*-internal overlay. Source-only public/SSO scaffolds are\n'
  printf '       experimental and are not included in release bundles.\n'
elif [[ "$TESTING_LOGIN_ENABLED" != true && "$AUTH_OVERLAY_ENABLED" != true ]]; then
  # A healthy stack that nobody can administer is not a valid deployment. Keep the shipped
  # value off so an operator must make the decision, but fail before startup until they do.
  bad "no dashboard login method is configured — the dashboard would load but nobody could sign in"
  printf '       Mobile ingest and the participant forms work; only researcher sign-in is absent.\n'
  printf '       Pick one:\n'
  printf '         built-in login  set TESTING_LOGIN_ENABLED=true AND REQUIRE_MFA=false\n'
  printf '                         (safe here: the dashboard is already behind the internal\n'
  printf '                          listener, the source allowlist and the global password)\n'
  printf '       Multi-user SSO is experimental and is not shipped in release bundles.\n'
else
  ok "dashboard login is configured and consistent with its exposure"
fi

# MFA enforcement and the built-in login are one decision, not two, and getting the pair
# wrong fails in opposite directions: REQUIRE_MFA=false on a public dashboard removes a real
# control, while REQUIRE_MFA=true with the built-in login produces a dashboard that logs in
# and then 401s every API call -- which reads as a broken deployment, not a setting.
if [[ "$REQUIRE_MFA" != true && "$DASHBOARD_EXPOSURE" != internal ]]; then
  bad "REQUIRE_MFA=false with DASHBOARD_EXPOSURE=${DASHBOARD_EXPOSURE}"
  printf '       That serves the dashboard API to anything that can reach this stack with no\n'
  printf '       multi-factor requirement on the token. Use a mode-*-internal overlay, or\n'
  printf '       leave REQUIRE_MFA=true for a separately reviewed identity-provider integration.\n'
elif [[ "$TESTING_LOGIN_ENABLED" == true && "$REQUIRE_MFA" == true ]]; then
  bad "TESTING_LOGIN_ENABLED=true with REQUIRE_MFA=true"
  printf '       The built-in login mints a token with no MFA claim, so the dashboard would\n'
  printf '       sign in and then reject every API call with 401 "Multi-factor authentication\n'
  printf '       is required". Set REQUIRE_MFA=false to use the built-in login (the dashboard\n'
  printf '       stays behind the internal listener, the allowlist and the password), or set\n'
  printf '       TESTING_LOGIN_ENABLED=false and deploy a separately reviewed identity provider.\n'
elif [[ "$REQUIRE_MFA" == true ]]; then
  ok "dashboard tokens must prove MFA (REQUIRE_MFA=true)"
else
  ok "MFA not required on dashboard tokens — gated by the internal listener, allowlist and password"
fi

# ------------------------------------------------------------------ dashboard gate
if [[ "$DASHBOARD_EXPOSURE" == internal ]]; then
  # Neither half of the gate is optional: without a hash Caddy accepts any password, and an
  # empty allowlist accepts any source.
  if [[ -z "$DASHBOARD_PASSWORD_HASH" ]]; then
    bad "DASHBOARD_PASSWORD_HASH is empty — the dashboard would have no password."
    printf '       Run ./chronicle setup, or use the stdin-based hash procedure in README.md;\n'
    printf '       never put the cleartext password in a command argument.\n'
  elif [[ "$DASHBOARD_PASSWORD_HASH" != \$2* ]]; then
    bad "DASHBOARD_PASSWORD_HASH is not a bcrypt hash (must start with \$2). Never put the cleartext password here."
  fi
  if [[ -z "$DASHBOARD_ALLOWED_IPS" ]]; then
    bad "DASHBOARD_ALLOWED_IPS is empty — no source address would be allowed to reach the dashboard"
  fi
  if [[ "$INTERNAL_BIND" == "0.0.0.0" ]]; then
    bad "INTERNAL_BIND=0.0.0.0 exposes the dashboard API to every network, defeating the internal mode"
  fi
  # The dashboard gate is one control with three parts -- bcrypt password, source allowlist,
  # private bind. Each part still fails on its own line with its own remedy, but when all
  # three hold, saying so three times makes the reader weigh them separately when the only
  # question that matters is whether the gate is shut.
  if ((FAILED == 0)); then
    ok "dashboard gate shut: bcrypt password, allowlist ${DASHBOARD_ALLOWED_IPS}, bound to ${INTERNAL_BIND}:${INTERNAL_PORT}"
  fi
elif [[ -n "$DASHBOARD_EXPOSURE" ]]; then
  warn "DASHBOARD_EXPOSURE=public — the dashboard API is reachable wherever this stack is. Prefer an internal mode unless something else restricts access."
fi

# ------------------------------------------------------------------ TLS material
# ./tls is mounted read-only. Docker creates a missing bind-mount source as an empty
# directory, so "the operator never made one" and "the operator made one and left it empty"
# arrive here identically -- both are equally wrong for own-tls, so both fail the same way.
TLS_CERT_DIR="${CHRONICLE_GUARD_TLS_DIR:-/tls}"
if [[ "$TLS_MODE" == own-tls ]]; then
  if [[ -s "${TLS_CERT_DIR}/cert.pem" && -s "${TLS_CERT_DIR}/key.pem" ]]; then
    ok "TLS certificate and key present in ./tls"
  else
    bad "TLS_MODE=own-tls but ./tls/cert.pem or ./tls/key.pem is missing or empty"
  fi
elif [[ "$TLS_MODE" == local-https ]]; then
  ok "TLS terminated here with Caddy's internal CA — no certificate to supply"
elif [[ -n "$TLS_MODE" ]]; then
  # No ok line: the "deployment mode:" check above already stated TLS_MODE, and repeating
  # it here is a second green line about a setting the operator has already been told.
  :
  if [[ "$HTTP_BIND" == "0.0.0.0" ]]; then
    warn "HTTP_BIND=0.0.0.0 serves plain HTTP to your whole network. Use 127.0.0.1 (or the address only your proxy can reach) unless you intend that."
  elif [[ "$HTTP_BIND" =~ ^127\. ]]; then
    # Nothing here can prove where the proxy runs, so this cannot be a hard failure -- a
    # proxy on this same host is a legitimate setup. It is still worth saying loudly,
    # because it is the one misconfiguration every local check passes: an off-host load
    # balancer gets connection refused while everything on this box looks healthy.
    warn "HTTP_BIND=${HTTP_BIND} is loopback, reachable only from this machine. Correct if your proxy runs here; if your load balancer is on another host it will get connection refused. Set HTTP_BIND to an address the proxy can reach."
  fi
fi

echo
if [[ $FAILED -ne 0 ]]; then
  write_configuration_metric 0
  printf '%sConfiguration is not safe to deploy.%s Nothing was started.\n' "$RED" "$RST" >&2
  printf 'Fix the FAIL lines above in .env, then run `docker compose up -d` again.\n' >&2
  exit 1
fi
write_configuration_metric 1
# No success banner here. This script is one of two check phases, and its caller prints the
# single verdict once both have passed -- "Configuration is valid" from ./chronicle check,
# or the startup line from ./chronicle up. Announcing success mid-run trained the eye to
# stop reading at a green line that was not the final answer.
