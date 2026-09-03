#!/usr/bin/env bash
# Single-source-of-truth check for the self-host bundle.
#
#   ./verify-config.sh
#
# A configuration value in this bundle can appear in up to four places:
#
#   .env.example          what the operator is told to set
#   docker-compose.yml    what is passed into the backend container
#   backend-entrypoint.sh the default applied when it is unset
#   config/*.template     where it is actually consumed
#
# Nothing enforces that those agree, and the failure is silent: add ${FOO} to a template,
# forget the compose passthrough, and the entrypoint's default is used instead of the
# operator's value with no warning. This script makes that a hard error.
#
# It also checks that all three supported Caddyfile variants share one route definition,
# so their public-ingest and private-dashboard listeners cannot drift.
set -uo pipefail

cd "$(dirname "$0")" || exit 1

FAILED=0
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }

vars_in() { grep -ohE '\$\{[A-Z_][A-Z0-9_]*' "$@" 2>/dev/null | sed 's/\${//' | sort -u; }

TEMPLATE_VARS=$(vars_in config/*.template)
ENTRYPOINT_DEFAULTS=$(grep -oE '^: "\$\{[A-Z_][A-Z0-9_]*' backend-entrypoint.sh | sed 's/.*{//' | sort -u)
ENTRYPOINT_REQUIRED=$(sed -n 's/^for required in \(.*\); do/\1/p' backend-entrypoint.sh | tr ' ' '\n' | sort -u)
# A third way the entrypoint can guarantee a value: compute one. CHRONICLE_INTERNAL_WEB_SECRET
# is generated per boot rather than defaulted, so it never takes the `: "${VAR:=...}"` shape,
# but envsubst is just as certain to find it set.
ENTRYPOINT_GENERATED=$(grep -oE '^[[:space:]]*[A-Z_][A-Z0-9_]*="?\$\(' backend-entrypoint.sh |
  sed 's/=.*//; s/^[[:space:]]*//' | sort -u)
ENV_EXAMPLE_VARS=$(grep -oE '^#? *[A-Z_][A-Z0-9_]*=' .env.example | tr -d '# =' | sort -u)
# Only the backend service's environment block — a plain grep would also pick up
# postgres's POSTGRES_INITDB_ARGS and friends, which the backend never sees.
COMPOSE_PASSED=$(awk '
  /^  [a-z]/            { in_svc = ($0 ~ /^  backend:/); in_env = 0 }
  in_svc && /^    environment:/ { in_env = 1; next }
  in_svc && /^    [a-z]/       { in_env = 0 }
  in_env && /^      [A-Z_]/    { sub(/:.*/, ""); gsub(/ /, ""); print }
' docker-compose.yml | sort -u)

echo "Config contract"

# 1. Every variable a template consumes must be either defaulted or required at boot.
#    Otherwise envsubst yields an empty string and the backend parses invalid YAML.
missing_default=$(comm -23 <(echo "$TEMPLATE_VARS") \
  <(sort -u <(echo "$ENTRYPOINT_DEFAULTS") <(echo "$ENTRYPOINT_REQUIRED") <(echo "$ENTRYPOINT_GENERATED")))
if [[ -n "$missing_default" ]]; then
  fail "template vars with no default, generator, or required-check in backend-entrypoint.sh:"
  echo "$missing_default" | sed 's/^/         /'
else
  ok "every config/*.template variable is defaulted or required ($(echo "$TEMPLATE_VARS" | wc -l) vars)"
fi

# 2. Every secret the entrypoint hard-requires must be documented for the operator.
undocumented=$(comm -23 <(echo "$ENTRYPOINT_REQUIRED") <(echo "$ENV_EXAMPLE_VARS"))
if [[ -n "$undocumented" ]]; then
  fail "required secrets absent from .env.example: $(echo "$undocumented" | tr '\n' ' ')"
else
  ok "required secrets are documented in .env.example"
fi

# 3. Every required secret must actually reach the container.
not_passed=$(comm -23 <(echo "$ENTRYPOINT_REQUIRED") <(echo "$COMPOSE_PASSED"))
if [[ -n "$not_passed" ]]; then
  fail "required secrets not passed to backend in docker-compose.yml: $(echo "$not_passed" | tr '\n' ' ')"
else
  ok "required secrets are passed through docker-compose.yml"
fi

# 4. A value passed by compose but never consumed is dead config the operator will
#    reasonably expect to do something.
for v in $COMPOSE_PASSED; do
  # CHRONICLE_SECURITY_* are bound by Spring relaxed binding inside the app, not by a template.
  # LOG_DIR is read by chronicle-server/src/main/resources/log4j2.xml
  # (${env:LOG_DIR:-/var/log/chronicle}), which is inside the image and not visible here.
  # CHRONICLE_EXPORT_DIR is consumed directly by ExportFileWriter for persistent managed
  # export artifacts. LOG_FORMAT is read directly by log4j2.xml. Neither passes through a
  # rendered config template.
  case "$v" in CHRONICLE_SERVER_*|CHRONICLE_SECURITY_*|CHRONICLE_EXPORT_DIR|POSTGRES_HOST|POSTGRES_PORT|LOG_DIR|LOG_FORMAT) continue ;; esac
  if ! grep -q "\${$v}" config/*.template 2>/dev/null && ! grep -q "\${$v:" backend-entrypoint.sh 2>/dev/null; then
    fail "docker-compose.yml passes $v to the backend but nothing consumes it"
  fi
done
[[ $FAILED -eq 0 ]] && ok "no dead variables passed to the backend"

# 4b. A value the operator is told to set, which a template consumes, but which never
#     reaches the container: the entrypoint default wins and the setting silently does
#     nothing. This is worse than an error -- TESTING_LOGIN_ENABLED=true looked applied.
silent=$(comm -12 <(echo "$TEMPLATE_VARS") <(echo "$ENV_EXAMPLE_VARS") | comm -23 - <(echo "$COMPOSE_PASSED"))
if [[ -n "$silent" ]]; then
  fail "documented in .env.example and used by a template, but not passed to the backend (setting them does nothing): $(echo "$silent" | tr '\n' ' ')"
else
  ok "every documented setting a template consumes actually reaches the backend"
fi

# The same dashboard password gates Caddy and the backend session-minting endpoint.
# Merely validating the Caddy bcrypt hash is insufficient: without this rendered field,
# Basic auth succeeds but POST /chronicle/v3/auth/dashboard-login rejects every password.
if grep -Fq 'dashboardPasswordHash: "${DASHBOARD_PASSWORD_HASH}"' config/chronicle-auth.yaml.template; then
  ok "dashboard bcrypt hash is rendered into the backend auth configuration"
else
  fail "config/chronicle-auth.yaml.template does not render DASHBOARD_PASSWORD_HASH for dashboard sessions"
fi

echo
echo "Route definitions"

# 5. Every supported listener must import the shared snippets rather than inlining routes,
#    or its public-ingest and private-dashboard lists can silently diverge. Public-dashboard
#    variants are source-only files under experimental/ and are not part of this contract.
CADDYFILES="Caddyfile.split Caddyfile.split.local Caddyfile.split.tls"
for f in $CADDYFILES; do
  if ! grep -q '^import snippets.caddy' "$f"; then
    fail "$f does not import snippets.caddy"
  elif grep -qE '^[[:space:]]*reverse_proxy /chronicle' "$f"; then
    fail "$f defines routes inline instead of importing them from caddy/snippets.caddy"
  else
    ok "$f imports the shared route definitions"
  fi
done
if ! grep -Fq 'respond /datastore/* 404' caddy/snippets.caddy; then
  fail "shared Caddy deny rules do not block the retired top-level /datastore/* alias"
else
  ok "shared Caddy deny rules block the retired top-level /datastore/* alias"
fi

for access_log_filter in \
  'format filter {' \
  'request>headers delete' \
  'request>uri delete' \
  'request>remote_ip ip_mask 16 32' \
  'request>client_ip ip_mask 16 32' \
  'wrap json'; do
  if ! grep -Fq "$access_log_filter" caddy/snippets.caddy; then
    fail "caddy/snippets.caddy does not redact access-log field: ${access_log_filter}"
  fi
done

# 6. The direct backend/admin surfaces blocked by the hardened reference must be refused here on
#    every listener, including the internal one.
for f in $CADDYFILES; do
  if ! grep -q 'import chronicle_deny_direct' "$f"; then
    fail "$f does not deny the direct backend routes (/chronicle/datastore, /principal, ...)"
  else
    ok "$f denies direct backend/admin routes"
  fi
done

# 7. Anything reverse-proxied must not also be denied, and vice versa — a prefix appearing
#    in both lists means one of them is dead and the intent is ambiguous.
#    `handle <prefix> { … reverse_proxy … }` counts as proxying that prefix too — the web
#    API is served that way so its rewrite cannot un-match its own block.
proxied=$(grep -oE '(reverse_proxy|handle) (/chronicle|/prometheus)[^ ]*' caddy/snippets.caddy | awk '{print $2}' | sort -u)
denied=$(grep -oE 'respond (/chronicle|/prometheus)[^ ]* 404' caddy/snippets.caddy | awk '{print $2}' | sort -u)
overlap=$(comm -12 <(echo "$proxied") <(echo "$denied"))
# chronicle_deny_dashboard_api deliberately mirrors chronicle_dashboard_api for the split
# public listener, so those are expected; anything else is not.
unexpected=$(comm -23 <(echo "$overlap") <(printf '%s\n' '/chronicle/api/web/*' '/chronicle/limits/*' | sort))
if [[ -n "$unexpected" ]]; then
  fail "prefixes both proxied and denied outside the split mirror: $(echo "$unexpected" | tr '\n' ' ')"
else
  ok "proxy and deny lists do not contradict each other"
fi

# Every network surface used by the Android ChronicleStudyApi must reach the backend on the
# public listener. v4 covers enrollment, uploads, reminders, consent acknowledgments, and
# withdrawal; v3 covers settings; v2 covers the legacy EDM lookup; /chronicle/study carries
# installed-client status/questionnaire compatibility. /health must reflect backend dependency
# readiness rather than returning an edge-only static success.
for route_contract in \
  'reverse_proxy /chronicle/v2/* backend:40320' \
  'reverse_proxy /chronicle/v3/* backend:40320' \
  'reverse_proxy /chronicle/v4/* backend:40320' \
  'reverse_proxy /chronicle/study/* backend:40320' \
  'handle /health' \
  'rewrite * /chronicle/internal/health/ready' \
  'reverse_proxy backend:40320'; do
  if ! grep -Fq "$route_contract" caddy/snippets.caddy; then
    fail "Android mobile contract is missing public route: $route_contract"
  else
    ok "Android mobile contract exposes: $route_contract"
  fi
done

service_block() {
  awk -v service="$1" '
    $0 == "  " service ":" { in_service = 1; next }
    in_service && /^  [a-zA-Z0-9_-]+:$/ { exit }
    in_service { print }
  ' docker-compose.yml
}

echo
echo "Public origin validation"

public_host_validation_ok=true
for accepted_host in \
  'research.example.org' \
  '8.8.8.8' \
  '[2606:4700:4700::1111]'; do
  if ! ./guard-config.sh --validate-public-host "$accepted_host"; then
    fail "configuration guard rejects public host ${accepted_host}"
    public_host_validation_ok=false
  fi
done
for rejected_host in \
  '0.0.0.0' \
  '10.0.0.1' \
  '100.64.0.1' \
  '127.0.0.1' \
  '169.254.1.1' \
  '172.16.0.1' \
  '192.168.1.1' \
  '192.0.2.1' \
  '198.51.100.1' \
  '203.0.113.1' \
  '198.18.0.1' \
  '224.0.0.1' \
  '255.255.255.255' \
  'https://research.example.org' \
  'research.example.org/path' \
  'research.example.org:0' \
  'research.example.org:65536' \
  'https://localhost' \
  'https://reviewer.local' \
  'https://[::1]' \
  'https://[::ffff:192.0.2.1]' \
  'https://[2001:db8::1]' \
  'https://[fd00::1]' \
  'https://[fe80::1]' \
  'https://[ff02::1]' \
  '999.999.999.999'; do
  if ./guard-config.sh --validate-public-host "$rejected_host"; then
    fail "configuration guard accepts clearly non-public host ${rejected_host}"
    public_host_validation_ok=false
  fi
done
for accepted_origin in \
  'https://research.example.org' \
  'https://8.8.8.8' \
  'https://1.1.1.1:8443' \
  'https://[2606:4700:4700::1111]'; do
  if ! ./guard-config.sh --validate-public-origin "$accepted_origin"; then
    fail "configuration guard rejects HTTPS root origin ${accepted_origin}"
    public_host_validation_ok=false
  fi
done
for rejected_origin in \
  'research.example.org' \
  'http://research.example.org' \
  'ftp://research.example.org' \
  'https://user@research.example.org' \
  'https://research.example.org/' \
  'https://research.example.org/path' \
  'https://research.example.org?query=1' \
  'https://research.example.org#fragment' \
  'https://research.example.org:0' \
  'https://research.example.org:65536'; do
  if ./guard-config.sh --validate-public-origin "$rejected_origin"; then
    fail "configuration guard accepts invalid public root origin ${rejected_origin}"
    public_host_validation_ok=false
  fi
done
if ! grep -Fq 'local_trial_origin="https://${DOMAIN}"' guard-config.sh ||
   ! grep -Fq 'local_trial_origin+=":${local_https_port}"' guard-config.sh ||
   ! grep -Fq 'CHRONICLE_PUBLIC_BASE_URL must be empty or exactly ${local_trial_origin}' guard-config.sh; then
  fail "local trial mode does not bind its participant origin to DOMAIN and its selected HTTPS port"
else
  ok "local trial mode binds its participant origin to DOMAIN and its selected HTTPS port"
fi
if [[ "$public_host_validation_ok" == true ]]; then
  ok "public modes require valid public hosts and exact HTTPS root origins"
fi

config_guard_service=$(service_block config-guard)
if ! grep -Fq 'CHRONICLE_PUBLIC_BASE_URL:' <<<"$config_guard_service"; then
  fail "config-guard cannot validate an explicit CHRONICLE_PUBLIC_BASE_URL"
else
  ok "config-guard receives an explicit CHRONICLE_PUBLIC_BASE_URL"
fi

backend_service=$(service_block backend)
web_service=$(service_block web)
if ! grep -Fq '/chronicle/internal/health/ready' <<<"$backend_service"; then
  fail "backend healthcheck does not use dependency-aware readiness"
elif grep -Fq '/chronicle/v3/study' <<<"$backend_service"; then
  fail "backend healthcheck still treats an arbitrary study API response as healthy"
else
  ok "backend healthcheck uses dependency-aware readiness"
fi
if ! grep -A2 -F 'backend:' <<<"$web_service" | grep -Fq 'condition: service_healthy'; then
  fail "web starts before the backend is dependency-ready"
else
  ok "web waits for dependency-aware backend health"
fi

if ! grep -Fq 'window.__CHRONICLE_RUNTIME_CONFIG__' caddy/snippets.caddy ||
   ! grep -Fq 'serverUrl: "{$CHRONICLE_PUBLIC_BASE_URL}"' caddy/snippets.caddy ||
   ! grep -Fq 'allowPrivateServerUrl: {$CHRONICLE_ALLOW_PRIVATE_ENROLLMENT_ORIGIN:false}' caddy/snippets.caddy ||
   ! grep -Fq 'CHRONICLE_PUBLIC_BASE_URL:' <<<"$web_service"; then
  fail "self-host dashboard does not use the canonical participant-facing public origin"
elif ! grep -Fq 'CHRONICLE_ALLOW_PRIVATE_ENROLLMENT_ORIGIN: "true"' overlays/mode-local-https.yml; then
  fail "local HTTPS trial does not explicitly permit its LAN enrollment origin"
elif grep -R -F -l \
  'CHRONICLE_ALLOW_PRIVATE_ENROLLMENT_ORIGIN: "true"' \
  overlays \
  --exclude='mode-local-https.yml' \
  | grep -q .; then
  fail "a production-facing deployment mode enables private enrollment origins"
else
  ok "self-host dashboard uses the canonical participant-facing public origin"
fi

if ! grep -Fq ': "${CHRONICLE_PUBLIC_BASE_URL:=https://${DOMAIN}}"' backend-entrypoint.sh ||
   ! grep -Fq 'public-base-url: "${CHRONICLE_PUBLIC_BASE_URL}"' config/mobile-security.yaml.template; then
  fail "enrollment manifests do not use the configured canonical https://DOMAIN origin"
else
  ok "enrollment manifests use the configured canonical public HTTPS origin"
fi

if grep -Fq 'SAN="${SAN},DNS:${DOMAIN}"' cert-init.sh; then
  fail "internal dashboard certificate claims the participant-facing DOMAIN"
  printf '       That certificate can shadow the local-CA/public certificate on Caddy\047s HTTPS listener.\n'
elif ! grep -Fq 'SAN="DNS:localhost,IP:127.0.0.1"' cert-init.sh ||
     ! grep -Fq 'INTERNAL_CERT_SANS' cert-init.sh; then
  fail "internal dashboard certificate SAN ownership is incomplete"
else
  ok "public and internal TLS certificate names cannot shadow one another"
fi

if ! grep -Fq 'keep_public_base_url=' chronicle ||
   ! grep -Fq "('CHRONICLE_PUBLIC_BASE_URL', public_base_url)" chronicle; then
  fail "rerunning setup discards an explicit participant-facing public origin"
else
  ok "rerunning setup preserves the participant-facing public origin"
fi

for reviewer_contract in \
  'reviewer-enrollment:' \
  'enabled: ${CHRONICLE_REVIEWER_ACCESS_ENABLED}' \
  'secret: "${CHRONICLE_REVIEWER_ACCESS_SECRET}"' \
  'study-id: "${CHRONICLE_REVIEWER_STUDY_ID}"' \
  'participant-id: "${CHRONICLE_REVIEWER_PARTICIPANT_ID}"'; do
  if ! grep -Fq "$reviewer_contract" config/mobile-security.yaml.template; then
    fail "reviewer bootstrap config is missing: $reviewer_contract"
  fi
done
[[ $FAILED -eq 0 ]] && ok "reviewer bootstrap is fully operator-configured and disabled by default"

if ! grep -Fq 'reviewer_scope_state()' chronicle ||
   ! grep -Fq 'doctor_add reviewer-scope' chronicle ||
   ! grep -Fq 'reviewer_scope_state()' rotate-secret.sh ||
   ! grep -Fq 'scope_state="$(reviewer_scope_state)"' rotate-secret.sh; then
  fail "reviewer setup can be enabled without verifying the live synthetic study/participant scope"
elif grep -Fq "participation_status IN ('NOT_ENROLLED', 'ENROLLED')" chronicle rotate-secret.sh ||
     ! grep -Fq "participation_status = '\''ENROLLED'\''" chronicle ||
     ! grep -Fq "participation_status = 'ENROLLED'" rotate-secret.sh; then
  fail "reviewer live-scope verification does not require an already-enrolled synthetic participant"
elif ! grep -Fq './chronicle doctor' README.md ||
     ! grep -Fq 'reviewer-scope' docs/CONFIGURATION.md; then
  fail "reviewer live-scope creation and reset checks are not documented"
else
  ok "doctor and reviewer rotation verify the live synthetic reviewer scope"
fi

if ! grep -Fq 'free_kb >= 20971520' chronicle ||
   ! grep -Fq 'doctor_add disk warn' chronicle ||
   ! grep -Fq 'free space falls below 20 GiB' chronicle; then
  fail "doctor treats a low filesystem percentage as fatal even when ample absolute space remains"
else
  ok "doctor distinguishes low percentage from less than 20 GiB of remaining space"
fi

if ! grep -Fq 'if ! read -r free_kb free_pct' chronicle ||
   ! grep -Fq 'free_pct=""' chronicle; then
  fail "doctor can exit before reporting an unreadable filesystem capacity"
else
  ok "doctor reports an unreadable filesystem capacity without set -e aborting early"
fi

for public_contract in \
  'redir /privacy /chronicle/privacy permanent' \
  'redir /withdrawal /chronicle/withdrawal permanent' \
  'redir /reviewer /chronicle/reviewer permanent' \
  'reverse_proxy /chronicle/v4/mobile/reviewer-enrollment backend:40320'; do
  if ! grep -Fq "$public_contract" caddy/snippets.caddy; then
    fail "public participant/reviewer route is missing: $public_contract"
  else
    ok "public route is explicit: $public_contract"
  fi
done
for f in $CADDYFILES; do
  imports=$(grep -c 'import chronicle_public_entrypoints' "$f")
  if [[ "$imports" -lt 2 ]]; then
    fail "$f does not expose policy/reviewer entrypoints on both listeners"
  elif ! awk '
      /^:8081 \{/ { inside = 1; entry = 0; gate = 0; next }
      inside && /import chronicle_public_entrypoints/ { entry = NR }
      inside && /import chronicle_dashboard_guard/ { gate = NR }
      inside && /^}/ { exit !(entry > 0 && gate > entry) }
      END { if (!inside) exit 1 }
    ' "$f"; then
    fail "$f puts public policy/reviewer entrypoints behind dashboard authentication"
  else
    ok "$f serves public policy/reviewer entrypoints before dashboard authentication"
  fi
done

# 8. The rate limiter is a compiled-in plugin, not a built-in. Release Compose must use
#    the dedicated digest-pinned Caddy image and every variant must declare the handler
#    order -- stock Caddy cannot parse the config.
if grep -q 'rate_limit' caddy/snippets.caddy; then
  if grep -q 'image: ${CADDY_IMAGE:?' docker-compose.yml && ! grep -q '^[[:space:]]*build:' docker-compose.yml; then
    ok "proxy uses the required pre-built Caddy release image"
  else
    fail "caddy/snippets.caddy uses rate_limit but Compose does not require the pre-built CADDY_IMAGE"
  fi
  for f in $CADDYFILES; do
    grep -q 'order rate_limit' "$f" || fail "$f uses rate_limit but never declares 'order rate_limit before basic_auth'"
  done
fi

# A release bundle is installable on a clean Linux host precisely because Compose never
# references the source workspace or invokes a local build. Keep this assertion close to
# the config checks operators already run.
if grep -q '^[[:space:]]*build:' docker-compose.yml overlays/*.yml; then
  fail "release Compose contains a local build: block — self-hosters must only pull pinned images"
else
  ok "release Compose contains no local source builds"
fi
if grep -qE 'context:[[:space:]]+\.\.|dockerfile:' docker-compose.yml overlays/*.yml; then
  fail "release Compose references source-workspace build paths"
else
  ok "release Compose has no source-workspace build paths"
fi

# The same operator command also supports the public source-clone path. Source images must
# be tied to the checked-out superproject revision; a fixed :source tag made `git pull`
# appear successful while the old backend/dashboard/proxy kept running indefinitely.
if grep -Fq "source_image_tag() { printf '%s-%s:source-%s" chronicle &&
    grep -Fq 'is_managed_source_image "${BACKEND_IMAGE:-}" backend' chronicle &&
    grep -Fq '"VCS_REF=$source_revision"' chronicle &&
    grep -Fq '"GIT_SHA=$source_revision"' chronicle &&
    grep -Fq 'build_managed_source_image_if_missing "$BACKEND_IMAGE"' chronicle &&
    grep -Fq 'build_managed_source_image_if_missing "$SELFHOST_FRONTEND_IMAGE"' chronicle &&
    grep -Fq 'build_managed_source_image_if_missing "$CADDY_IMAGE"' chronicle; then
  ok "source-clone images are revision-tagged and carry revision build metadata"
else
  fail "source-clone image handling can reuse revisions, omit metadata, or build local source under a custom tag"
fi
grep -Fq 'submodule status --recursive -- "${SOURCE_SUBMODULES[@]}"' chronicle \
  || fail "source-clone builds do not reject submodules that differ from the pinned revision"

if ! grep -Fq '/chronicle/v4/mobile/reviewer-enrollment' chronicle ||
   ! grep -Fq 'reviewer bootstrap minted a fresh one-time invitation with the configured credential' chronicle ||
   ! grep -Fq '5??)' chronicle; then
  fail "runtime verification does not test the exact reviewer route or explicitly reject server errors"
else
  ok "runtime verification tests the exact reviewer route and rejects server errors"
fi

for image_var in BACKEND_IMAGE SELFHOST_FRONTEND_IMAGE CADDY_IMAGE POSTGRES_IMAGE; do
  grep -Fq "image: \${${image_var}:?" docker-compose.yml \
    || fail "docker-compose.yml does not require ${image_var}"
done
grep -Fq 'image: ${CADDY_IMAGE:?' overlays/mode-local-https.yml \
  || fail "local HTTPS overlay does not require the release CADDY_IMAGE"

duplicate_env_keys="$(
  awk -F= '/^[A-Z][A-Z0-9_]*=/{print $1}' .env.example | sort | uniq -d
)"
if [[ -n "$duplicate_env_keys" ]]; then
  fail ".env.example assigns the same key more than once: $(printf '%s' "$duplicate_env_keys" | tr '\n' ' ')"
else
  ok ".env.example has one authority for every setting"
fi

if grep -REq -- '^[[:space:]]*-[[:space:]]+\./(backups|tls):' docker-compose.yml overlays/*.yml; then
  fail "mutable backups/TLS bind mounts bypass CHRONICLE_STATE_DIR"
else
  ok "mutable backups/TLS bind mounts use the release-independent state directory"
fi

echo
echo "Deployment modes"

# 9. Every Caddyfile variant must be reachable from some mode overlay, and every mode
#    overlay must agree with its own filename about what it deploys. This is the contract
#    that replaced the generated exposure.yml: the mode is now a static file the operator
#    names in COMPOSE_FILE, so nothing regenerates it and nothing else can correct it.
#    A drifting overlay is silent -- it mounts a real Caddyfile and starts a real stack,
#    just not the one the operator chose.
declare -A MODE_CADDYFILE=(
  [behind-proxy-internal]=Caddyfile.split
  [own-tls-internal]=Caddyfile.split.tls
  [local-https]=Caddyfile.split.local
)
seen_caddyfiles=""
for mode in "${!MODE_CADDYFILE[@]}"; do
  f="overlays/mode-${mode}.yml"
  want="${MODE_CADDYFILE[$mode]}"
  if [[ ! -f "$f" ]]; then
    fail "$f is missing — .env.example and docker-compose.yml both offer this mode"
    continue
  fi
  # The filename encodes TLS_MODE-DASHBOARD_EXPOSURE; both must be set on config-guard (so
  # the guard checks the right combination) and on cert-init (so it generates the right
  # certificate). Splitting on the LAST hyphen: 'behind-proxy' itself contains one.
  if [[ "$mode" == local-https ]]; then
    # The only mode whose name is not "<tls>-<exposure>": there is no public variant of a
    # trial mode whose CA nobody else trusts, so its exposure is internal by definition.
    want_tls=local-https; want_exposure=internal
  else
    want_tls="${mode%-*}"; want_exposure="${mode##*-}"
  fi
  for svc in config-guard cert-init; do
    block=$(awk -v s="  ${svc}:" '$0 == s {f=1; next} /^  [a-z]/ {f=0} f' "$f")
    [[ "$block" == *"TLS_MODE: ${want_tls}"* ]] \
      || fail "$f does not set TLS_MODE: ${want_tls} on ${svc}"
    [[ "$block" == *"DASHBOARD_EXPOSURE: ${want_exposure}"* ]] \
      || fail "$f does not set DASHBOARD_EXPOSURE: ${want_exposure} on ${svc}"
  done
  if ! grep -q "\./${want}:/etc/caddy/Caddyfile:ro" "$f"; then
    fail "$f does not mount ./${want} as the Caddyfile"
  else
    seen_caddyfiles="${seen_caddyfiles} ${want}"
    ok "overlays/mode-${mode}.yml deploys ${want}"
  fi
  # The internal listener and the own-tls listener both read certificates from the
  # release-independent state directory.
  if [[ "$want_exposure" == internal || "$want_tls" == own-tls ]]; then
    grep -Fq '${CHRONICLE_STATE_DIR:-.}/tls:/etc/caddy/certs:ro' "$f" \
      || fail "$f needs state-dir TLS mounted at /etc/caddy/certs — Caddy would fail to load its certificate"
  fi
done
for f in $CADDYFILES; do
  case " ${seen_caddyfiles} " in
    *" $f "*) ;;
    *) fail "$f is not deployed by any overlays/mode-*.yml — it is dead config" ;;
  esac
done

# 10. The base compose file must NOT publish ports or mount a Caddyfile of its own. If it
#     did, a mode overlay could only add to it, so a stack composed with the internal mode
#     would still publish the public-mode listener alongside it.
if awk '/^  web:/{f=1;next} /^  [a-z]/{f=0} f' docker-compose.yml | grep -qE '^\s+(ports:|- \./Caddyfile)'; then
  fail "docker-compose.yml publishes ports or mounts a Caddyfile on 'web' — that belongs to the mode overlay, and cannot be overridden away by one"
else
  ok "base compose leaves ports and the Caddyfile entirely to the mode overlay"
fi

# 11. Everything that used to be a step in ./chronicle must exist as a service, or
#     `docker compose up -d` silently produces a stack with unencrypted tables, no
#     dashboard certificate and a world-readable ./backups.
for svc in config-guard cert-init db-init; do
  grep -q "^  ${svc}:" docker-compose.yml \
    || fail "docker-compose.yml has no ${svc} service — plain 'docker compose up -d' would skip what it does"
done
grep -q 'db-init:' <(awk '/^  backend:/{f=1;next} /^  [a-z]/{f=0} f' docker-compose.yml) \
  || fail "backend does not depend on db-init — Flyway would create tables before encryption is on"
ok "the one-shot services that make 'docker compose up -d' sufficient are all wired in"

# 12. The restore path. Piping a dump into a database that still has its schema skips every
#     CREATE and then appends every COPY, so a table without a primary key ends up holding
#     each row twice while psql exits 0 -- `audit` is such a table. The restore service drops
#     the schema first, which is the only reason that is not the documented procedure.
if ! grep -q '^  restore:' docker-compose.yml; then
  fail "docker-compose.yml has no restore service — operators are left piping dumps into psql, which silently doubles rows in tables with no primary key"
elif ! grep -q 'profiles:' <(awk '/^  restore:/{f=1;next} /^  [a-z]/{f=0} f' docker-compose.yml); then
  # Without the profile it is an ordinary service, so `docker compose up -d` would run it
  # and every boot would drop the schema and restore over it.
  fail "the restore service has no profiles: — 'docker compose up -d' would run it and wipe the database on every boot"
elif [[ ! -x restore.sh ]]; then
  fail "restore.sh is missing or not executable — the restore service cannot run"
else
  ok "restore runs only when named, and drops the schema before restoring"
fi

# 13. A timestamped principal key selected by rotate-secret must survive every future
#     db-init run. Re-selecting the bootstrap key on `down`/`up` makes rotation appear to
#     succeed until the first restart. The copied keyring is also the only way the encrypted
#     data volume can be remounted after losing its live keyring volume.
if ! grep -Fq "IF (SELECT key_name FROM pg_tde_key_info()) IS NULL THEN" init-tde.sh; then
  fail "init-tde.sh does not preserve an already active rotated principal key"
elif grep -Fq "IS DISTINCT FROM '\${KEY_NAME}'" init-tde.sh; then
  fail "init-tde.sh still forces the bootstrap key after an online rotation"
else
  ok "db-init preserves an active rotated TDE principal key"
fi
if ! grep -Fq 'source_digest="$(sha256sum "$KEYRING_SRC")"' db-init.sh ||
    ! grep -Fq '"$source_digest" == "$destination_digest"' db-init.sh; then
  fail "db-init does not byte-verify the recoverable keyring copy"
else
  ok "db-init byte-verifies the recoverable keyring copy"
fi

echo
if [[ $FAILED -ne 0 ]]; then
  echo "Config verification FAILED"
  exit 1
fi
echo "Config verified: no drift"
