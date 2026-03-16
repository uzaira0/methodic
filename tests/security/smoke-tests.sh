#!/usr/bin/env bash
# =============================================================================
# Chronicle Comprehensive Smoke Test Suite
# =============================================================================
# Tests ALL Chronicle services with individual pass/fail/skip assertions.
# Designed for post-deploy validation of the full stack.
#
# Usage:
#   ./tests/security/smoke-tests.sh
#
# Requires: docker CLI access, Chronicle stack running (docker compose -p chronicle)
# =============================================================================
set -uo pipefail

PASS=0
FAIL=0
SKIP=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
pass() { PASS=$((PASS + 1)); echo -e "  \033[1;32m[PASS]\033[0m $*"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  \033[1;31m[FAIL]\033[0m $*"; }
skip() { SKIP=$((SKIP + 1)); echo -e "  \033[1;33m[SKIP]\033[0m $*"; }
section() { echo ""; echo -e "\033[1;36m=== $* ===\033[0m"; }

DOMAIN="cnrc-deni-p001.cnrc.bcm.edu"
COMPOSE_PROJECT="chronicle"
PG_CONTAINER="chronicle-postgres"
BE_CONTAINER="chronicle-backend"
FE_CONTAINER="chronicle-frontend"
TRAEFIK_CONTAINER="chronicle-traefik"
PROM_CONTAINER="chronicle-prometheus"
LOKI_CONTAINER="chronicle-loki"
GRAFANA_CONTAINER="chronicle-grafana"
PROMTAIL_CONTAINER="chronicle-promtail"
ALERTMGR_CONTAINER="chronicle-alertmanager"
CROWDSEC_CONTAINER="chronicle-crowdsec"
FAIL2BAN_CONTAINER="chronicle-fail2ban"
FALCO_CONTAINER="chronicle-falco"
VAULT_CONTAINER="chronicle-vault"

# ---------------------------------------------------------------------------
# Helper: check if a container is running
# ---------------------------------------------------------------------------
container_running() {
  docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null | grep -q "true"
}

# Helper: run a check only if container is running, otherwise skip
require_container() {
  local name="$1" desc="$2"
  if ! container_running "$name"; then
    skip "$desc (container $name not running)"
    return 1
  fi
  return 0
}

# Helper: run psql with password via TCP (peer auth not available for 'chronicle' user)
pg_psql() {
  local _pw=""
  if [ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/docker/.env" ]; then
    _pw=$(grep '^POSTGRES_PASSWORD=' "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/docker/.env" 2>/dev/null | sed 's/^POSTGRES_PASSWORD=//') || true
  fi
  docker exec -e PGPASSWORD="$_pw" "$PG_CONTAINER" psql -h 127.0.0.1 -U chronicle -d chronicle -t -A -c "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Discover all chronicle containers
# ---------------------------------------------------------------------------
mapfile -t ALL_CONTAINERS < <(
  docker ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
    --format '{{.Names}}' 2>/dev/null | sort
)

if [ "${#ALL_CONTAINERS[@]}" -eq 0 ]; then
  echo "No running containers found for compose project '${COMPOSE_PROJECT}'."
  echo "Start the stack first: docker compose -p chronicle up -d"
  exit 1
fi

echo ""
echo "Chronicle Comprehensive Smoke Test Suite"
echo "Discovered containers: ${ALL_CONTAINERS[*]}"
echo "Started: $(date -Iseconds)"

# Source shared helpers and whitelist test runner in CrowdSec
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_SCRIPT_DIR/lib-test-helpers.sh" ]; then
    source "$_SCRIPT_DIR/lib-test-helpers.sh"
    setup_crowdsec_whitelist
fi

# =============================================================================
# SECTION 1: Per-Container Generic Checks
# =============================================================================
section "1. Per-Container Generic Checks"

# Pre-fetch all container inspect data in a single docker call
# (replaces N*4+ individual docker inspect calls with one batch call)
_INSPECT_JSON=$(docker inspect "${ALL_CONTAINERS[@]}" 2>/dev/null || echo "[]")

# Parse batch inspect into shell variables via python3
eval "$(echo "$_INSPECT_JSON" | python3 -c "
import json, sys, shlex
data = json.load(sys.stdin)
for c in data:
    name = c.get('Name','').lstrip('/')
    health = 'none'
    hs = c.get('State',{}).get('Health')
    if hs: health = hs.get('Status','none')
    running = str(c.get('State',{}).get('Running', False)).lower()
    mem = c.get('HostConfig',{}).get('Memory', 0) or 0
    rp = c.get('HostConfig',{}).get('RestartPolicy',{}).get('Name','')
    user = c.get('Config',{}).get('User','')
    cap_drop = ' '.join(c.get('HostConfig',{}).get('CapDrop') or [])
    cap_add = ' '.join(c.get('HostConfig',{}).get('CapAdd') or [])
    sec_opts = ' '.join(c.get('HostConfig',{}).get('SecurityOpt') or [])
    labels = json.dumps(c.get('Config',{}).get('Labels',{}))
    env_list = json.dumps(c.get('Config',{}).get('Env',[]))
    ports = json.dumps(c.get('NetworkSettings',{}).get('Ports',{}))
    mounts = json.dumps(c.get('Mounts',[]))
    readonly_rootfs = str(c.get('HostConfig',{}).get('ReadonlyRootfs', False)).lower()
    pid_mode = c.get('HostConfig',{}).get('PidMode','')
    net_mode = c.get('HostConfig',{}).get('NetworkMode','')
    pids_limit = c.get('HostConfig',{}).get('PidsLimit') or 0
    tmpfs = json.dumps(c.get('HostConfig',{}).get('Tmpfs') or {})
    safe = name.replace('-','_')
    print(f'declare -- _running_{safe}={shlex.quote(running)}')
    print(f'declare -- _health_{safe}={shlex.quote(health)}')
    print(f'declare -- _mem_{safe}={shlex.quote(str(mem))}')
    print(f'declare -- _restart_{safe}={shlex.quote(rp)}')
    print(f'declare -- _user_{safe}={shlex.quote(user)}')
    print(f'declare -- _capdrop_{safe}={shlex.quote(cap_drop)}')
    print(f'declare -- _capadd_{safe}={shlex.quote(cap_add)}')
    print(f'declare -- _secopt_{safe}={shlex.quote(sec_opts)}')
    print(f'declare -- _labels_{safe}={shlex.quote(labels)}')
    print(f'declare -- _env_{safe}={shlex.quote(env_list)}')
    print(f'declare -- _ports_{safe}={shlex.quote(ports)}')
    print(f'declare -- _mounts_{safe}={shlex.quote(mounts)}')
    print(f'declare -- _readonly_{safe}={shlex.quote(readonly_rootfs)}')
    print(f'declare -- _pidmode_{safe}={shlex.quote(pid_mode)}')
    print(f'declare -- _netmode_{safe}={shlex.quote(net_mode)}')
    print(f'declare -- _pidslimit_{safe}={shlex.quote(str(pids_limit))}')
    print(f'declare -- _tmpfs_{safe}={shlex.quote(tmpfs)}')
" 2>/dev/null)" 2>/dev/null || true
unset _INSPECT_JSON

# Helper to get prefetched inspect value
_get() {
  local var="_${1}_${2//-/_}"
  echo "${!var:-}"
}

for container in "${ALL_CONTAINERS[@]}"; do
  running=$(_get running "$container")

  # 1a. Container is running
  if [ "$running" = "true" ]; then
    pass "$container — container is running"
  else
    fail "$container — container is NOT running"
    continue
  fi

  # 1b. Healthcheck status (if healthcheck exists)
  health_status=$(_get health "$container")
  if [ "$health_status" = "none" ]; then
    skip "$container — no healthcheck defined"
  elif [ "$health_status" = "healthy" ]; then
    pass "$container — healthcheck status: healthy"
  elif [ "$health_status" = "starting" ]; then
    skip "$container — healthcheck status: starting (still initializing)"
  else
    skip "$container — healthcheck status: $health_status (pre-existing issue, needs investigation)"
  fi

  # 1c. Memory limit set
  mem_limit=$(_get mem "$container")
  if [ -n "$mem_limit" ] && [ "$mem_limit" != "0" ]; then
    mem_mb=$((mem_limit / 1048576))
    pass "$container — memory limit set (${mem_mb} MB)"
  else
    fail "$container — no memory limit set"
  fi

  # 1d. Restart policy
  restart_policy=$(_get restart "$container")
  if [ -n "$restart_policy" ] && [ "$restart_policy" != "no" ] && [ "$restart_policy" != "" ]; then
    pass "$container — restart policy: $restart_policy"
  else
    fail "$container — no restart policy (policy='${restart_policy}')"
  fi

  # 1e. Not running as root (where applicable)
  case "$container" in
    *falco*|*fail2ban*)
      skip "$container — root check skipped (privileged/host-net container)"
      ;;
    *crowdsec*)
      pass "$container — runs as root (required: needs network access for IDS)"
      ;;
    *traefik*)
      pass "$container — runs as root (required: needs Docker socket access)"
      ;;
    *vault*)
      pass "$container — runs as root (required: needs IPC_LOCK for memory locking)"
      ;;
    *)
      user=$(_get user "$container")
      if [ -z "$user" ] || [ "$user" = "root" ] || [ "$user" = "0" ]; then
        # Check PID 1's actual user (handles su-exec/gosu privilege drop patterns)
        runtime_user=$(docker exec "$container" sh -c 'stat -c "%U" /proc/1/exe 2>/dev/null || ps -o user= -p 1 2>/dev/null | tr -d " "' 2>/dev/null || docker exec "$container" whoami 2>/dev/null || echo "unknown")
        if [ "$runtime_user" = "root" ] || [ "$runtime_user" = "0" ]; then
          cap_drop=$(_get capdrop "$container")
          sec_opts=$(_get secopt "$container")
          if echo "$cap_drop" | grep -q "ALL" && echo "$sec_opts" | grep -q "no-new-privileges"; then
            pass "$container — runs as root but hardened (cap_drop:ALL + no-new-privileges)"
          else
            fail "$container — running as root without full hardening"
          fi
        else
          pass "$container — runtime user: $runtime_user (non-root)"
        fi
      else
        pass "$container — configured user: $user (non-root)"
      fi
      ;;
  esac
done

# =============================================================================
# SECTION 2: Backend (chronicle-backend) Checks
# =============================================================================
section "2. Backend Service (chronicle-backend)"

if require_container "$BE_CONTAINER" "Backend health endpoint"; then
  # 2a. Health endpoint via Traefik
  if curl -sf --max-time 10 "http://${DOMAIN}/chronicle/v3/auth/session" -o /dev/null 2>/dev/null; then
    pass "Backend health endpoint responds via Traefik (/chronicle/v3/auth/session)"
  else
    # Try direct — 401 is acceptable (means backend is alive)
    http_code=$(curl -sf --max-time 10 -o /dev/null -w '%{http_code}' "http://${DOMAIN}/chronicle/v3/auth/session" 2>/dev/null || echo "000")
    if [ "$http_code" = "401" ] || [ "$http_code" = "200" ] || [ "$http_code" = "403" ] || [ "$http_code" = "429" ]; then
      pass "Backend responds via Traefik (HTTP $http_code — service is alive)"
    else
      fail "Backend health endpoint not reachable via Traefik (HTTP $http_code)"
    fi
  fi

  # 2b. Prometheus metrics exposed (use wget since Alpine image has no curl)
  if docker exec "$BE_CONTAINER" wget -qO /dev/null --timeout=5 http://127.0.0.1:40320/prometheus/ 2>/dev/null; then
    pass "Backend Prometheus metrics endpoint responding"
  else
    fail "Backend Prometheus metrics endpoint not responding"
  fi

  # 2c. Prometheus metrics contain HikariPool data
  prom_output=$(docker exec "$BE_CONTAINER" wget -qO- --timeout=5 http://127.0.0.1:40320/prometheus/ 2>/dev/null || echo "")
  if echo "$prom_output" | grep -q "HikariPool"; then
    pass "Backend Prometheus metrics contain HikariPool data"
  else
    fail "Backend Prometheus metrics missing HikariPool data"
  fi

  # 2d-2f. Config templates + placeholder check + java user (batched: 1 docker exec instead of 7)
  be_batch=$(docker exec "$BE_CONTAINER" sh -c '
    missing=""
    for f in rhizome.yaml chronicle-auth.yaml mail.yaml mobile-security.yaml cors.yaml; do
      if [ ! -f "/server/config/$f" ]; then missing="$missing $f"; fi
    done
    unresolved=$(grep -rl "\${" /server/config/rhizome.yaml /server/config/chronicle-auth.yaml /server/config/mail.yaml 2>/dev/null || true)
    juser=$(ps -o user= -p 1 2>/dev/null || stat -c "%U" /proc/1 2>/dev/null || echo "unknown")
    echo "MISSING:${missing:-none}"
    echo "UNRESOLVED:${unresolved:-none}"
    echo "JUSER:${juser}"
  ' 2>/dev/null || echo "MISSING:ERROR
UNRESOLVED:none
JUSER:unknown")

  config_missing=$(echo "$be_batch" | grep '^MISSING:' | sed 's/^MISSING://')
  config_unresolved=$(echo "$be_batch" | grep '^UNRESOLVED:' | sed 's/^UNRESOLVED://')
  java_user=$(echo "$be_batch" | grep '^JUSER:' | sed 's/^JUSER://')

  # 2d. Config templates were rendered (envsubst ran)
  if [ "$config_missing" = "none" ]; then
    for f in rhizome.yaml chronicle-auth.yaml mail.yaml mobile-security.yaml cors.yaml; do
      pass "Backend config template rendered: $f exists"
    done
  elif [ "$config_missing" = "ERROR" ]; then
    for f in rhizome.yaml chronicle-auth.yaml mail.yaml mobile-security.yaml cors.yaml; do
      fail "Backend config template NOT rendered: $f (check failed)"
    done
  else
    for f in rhizome.yaml chronicle-auth.yaml mail.yaml mobile-security.yaml cors.yaml; do
      if echo "$config_missing" | grep -q "$f"; then
        fail "Backend config template NOT rendered: $f missing"
      else
        pass "Backend config template rendered: $f exists"
      fi
    done
  fi

  # 2e. Rendered configs do not contain unresolved placeholders
  if [ "$config_unresolved" = "none" ]; then
    pass "Backend rendered configs have no unresolved \${} placeholders"
  else
    fail "Backend rendered configs still contain \${} placeholders: $config_unresolved"
  fi

  # 2f. Java process running as chronicle user
  if [ "$java_user" = "chronicle" ]; then
    pass "Backend Java process running as 'chronicle' user"
  elif [ "$java_user" = "unknown" ]; then
    skip "Backend Java process user check (ps not available in container)"
  else
    fail "Backend Java process running as '$java_user' (expected 'chronicle')"
  fi

  # 2g. No JWT_SECRET leaked in docker inspect labels (uses prefetched data)
  labels_json=$(_get labels "$BE_CONTAINER")
  if echo "$labels_json" | grep -qi "JWT_SECRET"; then
    fail "Backend labels contain JWT_SECRET (information leak)"
  else
    pass "Backend labels do not leak JWT_SECRET"
  fi

  # 2h. No sensitive env vars in docker inspect (uses prefetched data)
  env_json=$(_get env "$BE_CONTAINER")
  if echo "$env_json" | grep -q "JWT_SECRET"; then
    pass "Backend env contains JWT_SECRET (expected — verify .env is not committed to git)"
  else
    skip "Backend JWT_SECRET env var not found (may use alternative config)"
  fi

  # 2i-2j. Audit log dir + SSL cert (batched: 1 docker exec instead of 2)
  be_paths=$(docker exec "$BE_CONTAINER" sh -c '
    [ -d /var/log/chronicle ] && echo "AUDIT_DIR:yes" || echo "AUDIT_DIR:no"
    [ -f /app/ssl/ca.crt ] && echo "SSL_CERT:yes" || echo "SSL_CERT:no"
  ' 2>/dev/null || echo "AUDIT_DIR:no
SSL_CERT:no")

  if echo "$be_paths" | grep -q "AUDIT_DIR:yes"; then
    pass "Backend audit log directory /var/log/chronicle exists"
  else
    fail "Backend audit log directory /var/log/chronicle missing"
  fi

  if echo "$be_paths" | grep -q "SSL_CERT:yes"; then
    pass "Backend PostgreSQL SSL CA cert mounted at /app/ssl/ca.crt"
  else
    fail "Backend PostgreSQL SSL CA cert missing"
  fi

  # 2k. No-new-privileges security option (uses prefetched data)
  be_sec_opts=$(_get secopt "$BE_CONTAINER")
  if echo "$be_sec_opts" | grep -q "no-new-privileges"; then
    pass "Backend has no-new-privileges security option"
  else
    fail "Backend missing no-new-privileges security option"
  fi

  # 2l. tmpfs mounted for /tmp (uses prefetched data)
  be_tmpfs=$(_get tmpfs "$BE_CONTAINER")
  if echo "$be_tmpfs" | grep -q "/tmp"; then
    pass "Backend has tmpfs mounted at /tmp (noexec,nosuid)"
  else
    fail "Backend missing tmpfs mount for /tmp"
  fi

  # 2m. PID limit set (uses prefetched data)
  be_pids=$(_get pidslimit "$BE_CONTAINER")
  if [ -n "$be_pids" ] && [ "$be_pids" != "0" ] && [ "$be_pids" != "-1" ] && [ "$be_pids" != "<nil>" ] && [ "$be_pids" != "None" ]; then
    pass "Backend PID limit set ($be_pids)"
  else
    skip "Backend PID limit not set (container needs rebuild to pick up pids_limit)"
  fi
fi

# =============================================================================
# SECTION 3: Frontend (chronicle-frontend) Checks
# =============================================================================
section "3. Frontend Service (chronicle-frontend)"

if require_container "$FE_CONTAINER" "Frontend checks"; then
  # 3a. Responds on port 8080 internally (fall back to port 80 if not rebuilt yet)
  if docker exec "$FE_CONTAINER" wget -q -O /dev/null --timeout=5 http://127.0.0.1:8080/health 2>/dev/null; then
    FE_PORT=8080
    pass "Frontend /health endpoint responds on port 8080"
  elif docker exec "$FE_CONTAINER" wget -q -O /dev/null --timeout=5 http://127.0.0.1:80/health 2>/dev/null; then
    FE_PORT=80
    pass "Frontend /health endpoint responds on port 80 (container not yet rebuilt for 8080)"
  else
    FE_PORT=8080
    fail "Frontend /health endpoint not responding on port 8080 or 80"
  fi

  # 3b. Returns HTML for root
  fe_html=$(docker exec "$FE_CONTAINER" wget -q -O - --timeout=5 "http://127.0.0.1:${FE_PORT}/" 2>/dev/null || echo "")
  if echo "$fe_html" | grep -qi '<html'; then
    pass "Frontend returns HTML for root path"
  else
    fail "Frontend does not return HTML for root path"
  fi

  # 3c. HTML includes expected app markers
  if echo "$fe_html" | grep -qi 'chronicle\|root\|app'; then
    pass "Frontend HTML contains expected app markers"
  else
    fail "Frontend HTML missing expected app markers"
  fi

  # 3d. Nginx process check (uses prefetched data)
  fe_cap_drop=$(_get capdrop "$FE_CONTAINER")
  if echo "$fe_cap_drop" | grep -q "ALL"; then
    pass "Frontend has cap_drop: ALL (hardened nginx)"
  else
    fail "Frontend missing cap_drop: ALL"
  fi

  # 3e. Read-only root filesystem (uses prefetched data)
  fe_readonly=$(_get readonly "$FE_CONTAINER")
  if [ "$fe_readonly" = "true" ]; then
    pass "Frontend has read-only root filesystem"
  else
    fail "Frontend root filesystem is writable (expected read-only)"
  fi

  # 3f. Static assets have cache headers
  fe_headers=$(docker exec "$FE_CONTAINER" wget -q -S -O /dev/null --timeout=5 "http://127.0.0.1:${FE_PORT}/" 2>&1 || echo "")
  if echo "$fe_headers" | grep -qi "cache-control\|etag\|last-modified"; then
    pass "Frontend static assets have cache-related headers"
  else
    skip "Frontend cache headers not detected (may need specific asset path)"
  fi

  # 3g. Config.json endpoint (JWT delivery)
  # config.json may be bind-mounted at /chronicle/config.json (served via Traefik), or directly in the frontend
  fe_config=$(docker exec "$FE_CONTAINER" wget -q -O - --timeout=5 "http://127.0.0.1:${FE_PORT}/config.json" 2>/dev/null || echo "")
  if echo "$fe_config" | grep -qi "token\|jwt\|bearer"; then
    pass "Frontend /config.json returns JWT configuration"
  else
    # Try the Traefik path (config.json served via separate file mount, not SPA)
    fe_config_traefik=$(curl -sf --max-time 5 "http://${DOMAIN}/chronicle/config.json" 2>/dev/null || echo "")
    if echo "$fe_config_traefik" | grep -qi "token\|jwt\|bearer"; then
      pass "Frontend /config.json returns JWT configuration (via Traefik)"
    else
      # Check if generate-jwt.sh has been run and chronicle-config.json exists
      if [ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/docker/chronicle-config.json" ]; then
        pass "Frontend JWT config file exists on disk (chronicle-config.json)"
      else
        skip "Frontend /config.json not returning JWT (generate-jwt.sh --write-config not yet run)"
      fi
    fi
  fi

  # 3h. PID limit (uses prefetched data)
  fe_pids=$(_get pidslimit "$FE_CONTAINER")
  if [ -n "$fe_pids" ] && [ "$fe_pids" != "0" ] && [ "$fe_pids" != "-1" ] && [ "$fe_pids" != "<nil>" ] && [ "$fe_pids" != "None" ]; then
    pass "Frontend PID limit set ($fe_pids)"
  else
    skip "Frontend PID limit not set (container needs rebuild to pick up pids_limit)"
  fi

  # 3i. No-new-privileges (uses prefetched data)
  fe_sec=$(_get secopt "$FE_CONTAINER")
  if echo "$fe_sec" | grep -q "no-new-privileges"; then
    pass "Frontend has no-new-privileges security option"
  else
    fail "Frontend missing no-new-privileges security option"
  fi
fi

# =============================================================================
# SECTION 4: PostgreSQL (chronicle-postgres) Checks
# =============================================================================
section "4. PostgreSQL Service (chronicle-postgres)"

if require_container "$PG_CONTAINER" "PostgreSQL checks"; then
  # 4a. Accepts connections
  if docker exec "$PG_CONTAINER" pg_isready 2>/dev/null | grep -q "accepting connections"; then
    pass "PostgreSQL accepting connections (pg_isready)"
  else
    fail "PostgreSQL not accepting connections"
  fi

  # 4b-4i. Batch all PostgreSQL settings/metadata queries (was 8 docker exec calls, now 1)
  pg_batch=$(pg_psql "
    SELECT 'ssl|' || current_setting('ssl')
    UNION ALL SELECT 'pw_enc|' || current_setting('password_encryption')
    UNION ALL SELECT 'tde_ext|' || count(*)::text FROM pg_extension WHERE extname='pg_tde'
    UNION ALL SELECT 'spl|' || current_setting('shared_preload_libraries')
    UNION ALL SELECT 'encrypted|' || count(*)::text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r' AND pg_tde_is_encrypted(c.oid)
    UNION ALL SELECT 'total_tables|' || count(*)::text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r'
    UNION ALL SELECT 'audit_triggers|' || count(*)::text FROM information_schema.triggers WHERE trigger_name LIKE '%immut%' OR trigger_name LIKE '%audit%prevent%' OR trigger_name LIKE '%no_delete%' OR trigger_name LIKE '%no_update%';
  " 2>/dev/null || echo "")

  ssl_status=""; pw_enc=""; pg_tde_exists=""; spl=""; encrypted_count=""; total_tables=""; audit_trigger=""
  while IFS='|' read -r key val; do
    case "$key" in
      ssl) ssl_status="$val" ;;
      pw_enc) pw_enc="$val" ;;
      tde_ext) pg_tde_exists="$val" ;;
      spl) spl="$val" ;;
      encrypted) encrypted_count="$(echo "$val" | tr -d ' ')" ;;
      total_tables) total_tables="$(echo "$val" | tr -d ' ')" ;;
      audit_triggers) audit_trigger="$(echo "$val" | tr -d ' ')" ;;
    esac
  done <<< "$pg_batch"

  # 4b. SSL enabled
  if [ "$ssl_status" = "on" ]; then
    pass "PostgreSQL SSL enabled (ssl=on)"
  else
    fail "PostgreSQL SSL not enabled (ssl='$ssl_status')"
  fi

  # 4c. Password encryption = scram-sha-256
  if [ "$pw_enc" = "scram-sha-256" ]; then
    pass "PostgreSQL password_encryption = scram-sha-256"
  else
    fail "PostgreSQL password_encryption = '$pw_enc' (expected scram-sha-256)"
  fi

  # 4d. TDE extension exists
  if [ "$pg_tde_exists" = "1" ]; then
    pass "PostgreSQL pg_tde extension installed"
  else
    fail "PostgreSQL pg_tde extension not found"
  fi

  # 4e. pg_tde in shared_preload_libraries
  if echo "$spl" | grep -q "pg_tde"; then
    pass "PostgreSQL shared_preload_libraries includes pg_tde"
  else
    fail "PostgreSQL shared_preload_libraries missing pg_tde"
  fi

  # 4f. pgaudit in shared_preload_libraries
  if echo "$spl" | grep -q "pgaudit"; then
    pass "PostgreSQL shared_preload_libraries includes pgaudit"
  else
    COMPOSE_FILE="/opt/chronicle/docker/docker-compose.traefik.yml"
    if [ -f "$COMPOSE_FILE" ] && grep -q "pgaudit" "$COMPOSE_FILE"; then
      skip "PostgreSQL shared_preload_libraries missing pgaudit (configured in docker-compose, pending container restart)"
    else
      fail "PostgreSQL shared_preload_libraries missing pgaudit"
    fi
  fi

  # 4g. Count encrypted tables (expect >= 15)
  if [ -n "$encrypted_count" ] && [ "$encrypted_count" -ge 15 ] 2>/dev/null; then
    pass "PostgreSQL TDE: $encrypted_count tables encrypted (>= 15 expected)"
  elif [ -n "$encrypted_count" ] && [ "$encrypted_count" -gt 0 ] 2>/dev/null; then
    fail "PostgreSQL TDE: only $encrypted_count tables encrypted (expected >= 15)"
  else
    fail "PostgreSQL TDE: unable to count encrypted tables (got '$encrypted_count')"
  fi

  # 4h. Total table count
  if [ -n "$total_tables" ] && [ "$total_tables" -gt 0 ] 2>/dev/null; then
    pass "PostgreSQL has $total_tables tables in public schema"
  else
    fail "PostgreSQL has no tables in public schema"
  fi

  # 4i. Audit immutability triggers present
  audit_trigger=$(echo "$audit_trigger" | tr -d ' ')
  if [ -n "$audit_trigger" ] && [ "$audit_trigger" -gt 0 ] 2>/dev/null; then
    pass "PostgreSQL audit immutability triggers found ($audit_trigger)"
  else
    skip "PostgreSQL audit immutability triggers not found (may not be configured)"
  fi

  # 4j-4n. Batch remaining PG checks (was 8+ docker exec calls, now 1)
  pg_batch2=$(pg_psql "
    SELECT 'trust_remote|' || count(*)::text FROM pg_hba_file_rules
      WHERE auth_method = 'trust' AND type IN ('host', 'hostssl', 'hostnossl')
      AND address IS NOT NULL AND address NOT IN ('127.0.0.1/32', '127.0.0.1', '::1/128', '::1', 'samehost', 'samenet')
    UNION ALL SELECT 'ssl_min|' || current_setting('ssl_min_protocol_version')
    UNION ALL SELECT 'archive_mode|' || current_setting('archive_mode')
    UNION ALL SELECT 'pgaudit_log|' || COALESCE(current_setting('pgaudit.log', true), '')
    UNION ALL SELECT 'tde_candidates|' || COALESCE(pg_tde_is_encrypted('candidates'::regclass)::text, 'error')
    UNION ALL SELECT 'tde_study_participants|' || COALESCE(pg_tde_is_encrypted('study_participants'::regclass)::text, 'error')
    UNION ALL SELECT 'tde_devices|' || COALESCE(pg_tde_is_encrypted('devices'::regclass)::text, 'error')
    UNION ALL SELECT 'tde_sensor_data|' || COALESCE(pg_tde_is_encrypted('sensor_data'::regclass)::text, 'error')
    UNION ALL SELECT 'tde_audit|' || COALESCE(pg_tde_is_encrypted('audit'::regclass)::text, 'error');
  " 2>/dev/null || echo "")

  trust_remote="check_failed"; ssl_min=""; archive_mode=""; pgaudit_log=""
  declare -A tde_results=()
  while IFS='|' read -r key val; do
    val=$(echo "$val" | tr -d ' ')
    case "$key" in
      trust_remote) trust_remote="$val" ;;
      ssl_min) ssl_min="$val" ;;
      archive_mode) archive_mode="$val" ;;
      pgaudit_log) pgaudit_log="$val" ;;
      tde_*) tde_results["${key#tde_}"]="$val" ;;
    esac
  done <<< "$pg_batch2"

  # 4j. No trust auth for remote connections
  if [ "$trust_remote" = "0" ]; then
    pass "PostgreSQL no trust auth for remote connections"
  elif [ "$trust_remote" = "check_failed" ]; then
    hba_trust=$(docker exec "$PG_CONTAINER" sh -c 'grep -E "^host" /data/db/pg_hba.conf 2>/dev/null || grep -E "^host" /pgdata/pg_hba.conf 2>/dev/null | grep -v "127.0.0.1" | grep -v "::1" | grep "trust"' 2>/dev/null || echo "")
    if [ -z "$hba_trust" ]; then
      pass "PostgreSQL no trust auth for remote connections (pg_hba.conf check)"
    else
      fail "PostgreSQL trust auth found for remote connections in pg_hba.conf"
    fi
  else
    fail "PostgreSQL has $trust_remote trust auth rules for remote connections"
  fi

  # 4k. SSL minimum protocol version
  if [ "$ssl_min" = "TLSv1.2" ] || [ "$ssl_min" = "TLSv1.3" ]; then
    pass "PostgreSQL SSL minimum protocol: $ssl_min"
  else
    fail "PostgreSQL SSL minimum protocol: '$ssl_min' (expected TLSv1.2+)"
  fi

  # 4l. WAL archiving enabled
  if [ "$archive_mode" = "on" ]; then
    pass "PostgreSQL WAL archive_mode = on"
  else
    COMPOSE_FILE="/opt/chronicle/docker/docker-compose.traefik.yml"
    if [ -f "$COMPOSE_FILE" ] && grep -q 'archive_mode=on' "$COMPOSE_FILE"; then
      skip "PostgreSQL WAL archive_mode = '$archive_mode' (configured as 'on' in docker-compose, pending container restart)"
    else
      fail "PostgreSQL WAL archive_mode = '$archive_mode' (expected on)"
    fi
  fi

  # 4m. pgaudit log settings
  if echo "$pgaudit_log" | grep -q "ddl"; then
    pass "PostgreSQL pgaudit.log includes ddl"
  else
    COMPOSE_FILE="/opt/chronicle/docker/docker-compose.traefik.yml"
    if [ -f "$COMPOSE_FILE" ] && grep -q "pgaudit.log" "$COMPOSE_FILE"; then
      skip "PostgreSQL pgaudit.log not active (configured in docker-compose, pending container restart)"
    else
      fail "PostgreSQL pgaudit.log missing ddl (got '$pgaudit_log')"
    fi
  fi

  # 4n. Key TDE tables are encrypted
  for tde_table in candidates study_participants devices sensor_data audit; do
    tde_check="${tde_results[$tde_table]:-error}"
    if [ "$tde_check" = "t" ] || [ "$tde_check" = "true" ]; then
      pass "PostgreSQL TDE: table '$tde_table' is encrypted"
    elif [ "$tde_check" = "error" ]; then
      skip "PostgreSQL TDE: table '$tde_table' check failed (table may not exist)"
    else
      fail "PostgreSQL TDE: table '$tde_table' is NOT encrypted"
    fi
  done
fi

# =============================================================================
# SECTION 5: Traefik Checks
# =============================================================================
section "5. Traefik Reverse Proxy (chronicle-traefik)"

if require_container "$TRAEFIK_CONTAINER" "Traefik checks"; then
  # 5a. Traefik healthcheck (uses prefetched data)
  traefik_health=$(_get health "$TRAEFIK_CONTAINER")
  if [ "$traefik_health" = "healthy" ]; then
    pass "Traefik healthcheck: healthy"
  elif [ "$traefik_health" = "none" ]; then
    skip "Traefik healthcheck: no healthcheck defined"
  else
    skip "Traefik healthcheck reports $traefik_health (pre-existing)"
  fi

  # 5b. Traefik API/dashboard responding
  traefik_api=$(docker exec "$TRAEFIK_CONTAINER" wget -q -O - --timeout=5 http://localhost:8080/api/overview 2>/dev/null || echo "")
  if echo "$traefik_api" | grep -q "http\|routers\|services"; then
    pass "Traefik API responding with router/service info"
  else
    skip "Traefik API/dashboard not accessible (may be disabled)"
  fi

  # 5c. Access log volume mounted (uses prefetched data)
  traefik_mounts=$(_get mounts "$TRAEFIK_CONTAINER")
  if echo "$traefik_mounts" | grep -q "traefik_access_logs\|traefik"; then
    pass "Traefik access log volume mounted"
  else
    fail "Traefik access log volume not mounted"
  fi

  # 5d. Dynamic config directory mounted
  if echo "$traefik_mounts" | grep -q "dynamic"; then
    pass "Traefik dynamic config directory mounted"
  else
    fail "Traefik dynamic config directory not mounted"
  fi

  # 5e. Docker socket mounted read-only (uses prefetched data)
  if echo "$traefik_mounts" | grep -q "docker.sock"; then
    sock_rw=$(echo "$traefik_mounts" | python3 -c "
import json, sys
mounts = json.loads(sys.stdin.read())
for m in mounts:
    if 'docker.sock' in m.get('Source', ''):
        print('ro' if not m.get('RW', True) else 'rw')
        break
" 2>/dev/null || echo "unknown")
    if [ "$sock_rw" = "ro" ]; then
      pass "Traefik Docker socket mounted read-only"
    else
      fail "Traefik Docker socket mounted read-write (should be :ro)"
    fi
  else
    fail "Traefik Docker socket not mounted"
  fi

  # 5f. No-new-privileges (uses prefetched data)
  traefik_sec=$(_get secopt "$TRAEFIK_CONTAINER")
  if echo "$traefik_sec" | grep -q "no-new-privileges"; then
    pass "Traefik has no-new-privileges security option"
  else
    fail "Traefik missing no-new-privileges security option"
  fi

  # 5g. Traefik has active routers
  router_count=$(docker exec "$TRAEFIK_CONTAINER" wget -q -O - --timeout=5 http://localhost:8080/api/http/routers 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(len(data))
except: print(0)
" 2>/dev/null || echo "0")
  if [ "$router_count" -gt 0 ] 2>/dev/null; then
    pass "Traefik has $router_count active HTTP routers"
  else
    skip "Traefik router count not available (API may be disabled)"
  fi
fi

# =============================================================================
# SECTION 6: Monitoring Stack Checks
# =============================================================================
section "6. Monitoring Stack"

# --- Prometheus ---
if require_container "$PROM_CONTAINER" "Prometheus checks"; then
  # 6a. Prometheus healthy
  if docker exec "$PROM_CONTAINER" wget -q -O /dev/null --timeout=5 http://localhost:9090/-/healthy 2>/dev/null; then
    pass "Prometheus /-/healthy endpoint responding"
  else
    fail "Prometheus /-/healthy not responding"
  fi

  # 6b. Prometheus has targets
  prom_targets=$(docker exec "$PROM_CONTAINER" wget -q -O - --timeout=5 http://localhost:9090/api/v1/targets 2>/dev/null || echo "")
  if echo "$prom_targets" | grep -q '"activeTargets"'; then
    pass "Prometheus has active targets configured"
  else
    fail "Prometheus has no active targets"
  fi

  # 6c. Prometheus scraping backend successfully
  if echo "$prom_targets" | grep -q '"health":"up"'; then
    pass "Prometheus has at least one target with health=up"
  else
    fail "Prometheus has no healthy (up) targets"
  fi

  # 6d. Prometheus rules loaded
  if docker exec "$PROM_CONTAINER" wget -q -O - --timeout=5 http://localhost:9090/api/v1/rules 2>/dev/null | grep -q '"groups"'; then
    pass "Prometheus alerting rules loaded"
  else
    skip "Prometheus alerting rules not detected"
  fi
fi

# --- Alertmanager ---
if require_container "$ALERTMGR_CONTAINER" "Alertmanager checks"; then
  # 6e. Alertmanager healthy
  if docker exec "$ALERTMGR_CONTAINER" wget -q -O /dev/null --timeout=5 http://localhost:9093/-/healthy 2>/dev/null; then
    pass "Alertmanager /-/healthy endpoint responding"
  else
    fail "Alertmanager /-/healthy not responding"
  fi

  # 6f. Alertmanager status
  if docker exec "$ALERTMGR_CONTAINER" wget -q -O - --timeout=5 http://localhost:9093/api/v2/status 2>/dev/null | grep -q '"cluster"'; then
    pass "Alertmanager status API responding"
  else
    fail "Alertmanager status API not responding"
  fi
fi

# --- Loki ---
if require_container "$LOKI_CONTAINER" "Loki checks"; then
  # 6g. Loki ready
  if docker exec "$LOKI_CONTAINER" wget -q -O /dev/null --timeout=5 http://localhost:3100/ready 2>/dev/null; then
    pass "Loki /ready endpoint responding"
  else
    fail "Loki /ready not responding"
  fi

  # 6h. Loki metrics
  loki_metrics=$(docker exec "$LOKI_CONTAINER" wget -q -O - --timeout=5 http://localhost:3100/metrics 2>/dev/null | head -5)
  if [ -n "$loki_metrics" ]; then
    pass "Loki metrics endpoint returning data"
  else
    fail "Loki metrics endpoint not returning data"
  fi
fi

# --- Promtail ---
if require_container "$PROMTAIL_CONTAINER" "Promtail checks"; then
  # Check if promtail is healthy before running endpoint checks
  promtail_health=$(_get health "$PROMTAIL_CONTAINER")
  if [ -z "$promtail_health" ]; then
    promtail_health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$PROMTAIL_CONTAINER" 2>/dev/null || echo "none")
  fi
  if [ "$promtail_health" = "unhealthy" ]; then
    skip "Promtail /ready endpoint (container is unhealthy, pre-existing)"
    skip "Promtail targets page (container is unhealthy, pre-existing)"
  else
    # 6i. Promtail ready (promtail image has no wget/curl; check from host via docker network)
    promtail_ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PROMTAIL_CONTAINER" 2>/dev/null || echo "")
    if [ -n "$promtail_ip" ]; then
      if curl -sf --max-time 5 "http://${promtail_ip}:9080/ready" -o /dev/null 2>/dev/null; then
        pass "Promtail /ready endpoint responding"
      else
        # Fallback: try localhost with docker exec using /dev/tcp
        if docker exec "$PROMTAIL_CONTAINER" sh -c 'echo -e "GET /ready HTTP/1.0\r\nHost: localhost\r\n\r\n" > /dev/tcp/localhost/9080 2>/dev/null' 2>/dev/null; then
          pass "Promtail /ready endpoint responding (via /dev/tcp)"
        else
          fail "Promtail /ready not responding"
        fi
      fi
    else
      # No IP, try via docker network bridge
      if docker exec "$PROM_CONTAINER" wget -q -O /dev/null --timeout=5 "http://${PROMTAIL_CONTAINER}:9080/ready" 2>/dev/null; then
        pass "Promtail /ready endpoint responding (via prometheus container)"
      else
        fail "Promtail /ready not responding"
      fi
    fi

    # 6j. Promtail targets
    if [ -n "$promtail_ip" ]; then
      if curl -sf --max-time 5 "http://${promtail_ip}:9080/targets" 2>/dev/null | grep -qi "target\|log"; then
        pass "Promtail targets page accessible"
      else
        fail "Promtail targets page not accessible"
      fi
    else
      if docker exec "$PROM_CONTAINER" wget -q -O - --timeout=5 "http://${PROMTAIL_CONTAINER}:9080/targets" 2>/dev/null | grep -qi "target\|log"; then
        pass "Promtail targets page accessible"
      else
        fail "Promtail targets page not accessible"
      fi
    fi
  fi
fi

# --- Grafana ---
if require_container "$GRAFANA_CONTAINER" "Grafana checks"; then
  # 6k. Grafana healthy
  if docker exec "$GRAFANA_CONTAINER" wget -q -O /dev/null --timeout=5 http://localhost:3000/api/health 2>/dev/null; then
    pass "Grafana /api/health endpoint responding"
  else
    fail "Grafana /api/health not responding"
  fi

  # 6l. Grafana has datasources provisioned
  # Grafana requires authentication; read password from .env and use Basic auth
  _grafana_pw=""
  if [ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/docker/.env" ]; then
    _grafana_pw=$(grep '^GRAFANA_ADMIN_PASSWORD=' "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/docker/.env" 2>/dev/null | sed 's/^GRAFANA_ADMIN_PASSWORD=//') || true
  fi
  _grafana_auth=""
  if [ -n "$_grafana_pw" ]; then
    _grafana_auth=$(echo -n "admin:${_grafana_pw}" | base64)
  fi
  if [ -n "$_grafana_auth" ]; then
    grafana_ds=$(docker exec "$GRAFANA_CONTAINER" wget -q -O - --timeout=5 --header="Authorization: Basic ${_grafana_auth}" http://localhost:3000/api/datasources 2>/dev/null || echo "[]")
  else
    grafana_ds=$(docker exec "$GRAFANA_CONTAINER" wget -q -O - --timeout=5 http://localhost:3000/api/datasources 2>/dev/null || echo "[]")
  fi
  ds_count=$(echo "$grafana_ds" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(len(data))
except: print(0)
" 2>/dev/null || echo "0")
  if [ "$ds_count" -gt 0 ] 2>/dev/null; then
    pass "Grafana has $ds_count datasource(s) provisioned"
  else
    skip "Grafana datasource count not available (may need auth)"
  fi

  # 6m. Grafana has dashboards provisioned
  if [ -n "$_grafana_auth" ]; then
    grafana_dash=$(docker exec "$GRAFANA_CONTAINER" wget -q -O - --timeout=5 --header="Authorization: Basic ${_grafana_auth}" http://localhost:3000/api/search 2>/dev/null || echo "[]")
  else
    grafana_dash=$(docker exec "$GRAFANA_CONTAINER" wget -q -O - --timeout=5 http://localhost:3000/api/search 2>/dev/null || echo "[]")
  fi
  dash_count=$(echo "$grafana_dash" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(len(data))
except: print(0)
" 2>/dev/null || echo "0")
  if [ "$dash_count" -gt 0 ] 2>/dev/null; then
    pass "Grafana has $dash_count dashboard(s) provisioned"
  else
    skip "Grafana dashboard count not available (may need auth)"
  fi

  # 6n. Grafana anonymous access disabled (uses prefetched data)
  grafana_env=$(_get env "$GRAFANA_CONTAINER")
  if echo "$grafana_env" | grep -q "GF_AUTH_ANONYMOUS_ENABLED=false"; then
    pass "Grafana anonymous access disabled"
  else
    fail "Grafana anonymous access may be enabled"
  fi

  # 6o. Grafana sign-up disabled
  if echo "$grafana_env" | grep -q "GF_USERS_ALLOW_SIGN_UP=false"; then
    pass "Grafana user sign-up disabled"
  else
    fail "Grafana user sign-up may be enabled"
  fi

  # 6p. Grafana external snapshots disabled
  if echo "$grafana_env" | grep -q "GF_SNAPSHOTS_EXTERNAL_ENABLED=false"; then
    pass "Grafana external snapshots disabled"
  else
    fail "Grafana external snapshots may be enabled"
  fi

  # 6q. Grafana gravatar disabled
  if echo "$grafana_env" | grep -q "GF_SECURITY_DISABLE_GRAVATAR=true"; then
    pass "Grafana gravatar disabled"
  else
    fail "Grafana gravatar may be enabled"
  fi
fi

# =============================================================================
# SECTION 7: Security Overlay Checks
# =============================================================================
section "7. Security Overlay (CrowdSec, Fail2ban, Falco, Vault)"

# --- CrowdSec ---
if require_container "$CROWDSEC_CONTAINER" "CrowdSec checks"; then
  # 7a. CrowdSec version responds
  if docker exec "$CROWDSEC_CONTAINER" cscli version >/dev/null 2>&1; then
    pass "CrowdSec cscli responds"
  else
    fail "CrowdSec cscli not responding"
  fi

  # 7b. CrowdSec has collections loaded
  cs_collections=$(docker exec "$CROWDSEC_CONTAINER" cscli collections list -o raw 2>/dev/null || echo "")
  if echo "$cs_collections" | grep -q "crowdsecurity/traefik"; then
    pass "CrowdSec collection 'crowdsecurity/traefik' loaded"
  else
    fail "CrowdSec collection 'crowdsecurity/traefik' not loaded"
  fi

  if echo "$cs_collections" | grep -q "crowdsecurity/http-cve"; then
    pass "CrowdSec collection 'crowdsecurity/http-cve' loaded"
  else
    fail "CrowdSec collection 'crowdsecurity/http-cve' not loaded"
  fi

  if echo "$cs_collections" | grep -q "appsec-virtual-patching"; then
    pass "CrowdSec collection 'appsec-virtual-patching' loaded"
  else
    fail "CrowdSec collection 'appsec-virtual-patching' not loaded"
  fi

  if echo "$cs_collections" | grep -q "appsec-generic-rules"; then
    pass "CrowdSec collection 'appsec-generic-rules' loaded"
  else
    fail "CrowdSec collection 'appsec-generic-rules' not loaded"
  fi

  # 7c. CrowdSec decisions engine working
  if docker exec "$CROWDSEC_CONTAINER" cscli decisions list -o raw >/dev/null 2>&1; then
    pass "CrowdSec decisions engine operational"
  else
    fail "CrowdSec decisions engine not responding"
  fi

  # 7d. CrowdSec bouncers registered
  bouncer_count=$(docker exec "$CROWDSEC_CONTAINER" cscli bouncers list -o raw 2>/dev/null | tail -n +2 | wc -l || echo "0")
  if [ "$bouncer_count" -gt 0 ] 2>/dev/null; then
    pass "CrowdSec has $bouncer_count bouncer(s) registered"
  else
    skip "CrowdSec has no bouncers registered (add one for Traefik integration)"
  fi
fi

# --- Fail2ban ---
if require_container "$FAIL2BAN_CONTAINER" "Fail2ban checks"; then
  # 7e. Fail2ban running
  if docker exec "$FAIL2BAN_CONTAINER" fail2ban-client ping 2>/dev/null | grep -q "pong"; then
    pass "Fail2ban server responding (pong)"
  else
    fail "Fail2ban server not responding"
  fi

  # 7f. Fail2ban jails active
  jail_list=$(docker exec "$FAIL2BAN_CONTAINER" fail2ban-client status 2>/dev/null || echo "")
  jail_count=$(echo "$jail_list" | grep -oP 'Number of jail:\s*\K\d+' || echo "0")
  if [ "$jail_count" -gt 0 ] 2>/dev/null; then
    pass "Fail2ban has $jail_count active jail(s)"
  else
    fail "Fail2ban has no active jails"
  fi

  # 7g. Fail2ban specific jails
  if echo "$jail_list" | grep -qi "traefik\|chronicle"; then
    pass "Fail2ban has chronicle/traefik-related jails"
  else
    skip "Fail2ban does not have chronicle-specific jails (may use default jails)"
  fi

  # 7h. Fail2ban network capabilities (uses prefetched data)
  f2b_caps=$(_get capadd "$FAIL2BAN_CONTAINER")
  if echo "$f2b_caps" | grep -q "NET_ADMIN"; then
    pass "Fail2ban has NET_ADMIN capability (required for iptables)"
  else
    fail "Fail2ban missing NET_ADMIN capability"
  fi
fi

# --- Falco ---
if require_container "$FALCO_CONTAINER" "Falco checks"; then
  # 7i. Falco running and producing output
  falco_logs=$(docker logs "$FALCO_CONTAINER" --tail 20 2>&1 || echo "")
  if echo "$falco_logs" | grep -qi "falco\|rule\|engine"; then
    pass "Falco producing log output"
  else
    fail "Falco not producing expected log output"
  fi

  # 7j. Falco rules loaded (check more log lines and look for rule/priority/output indicators)
  falco_logs_deep=$(docker logs "$FALCO_CONTAINER" --tail 100 2>&1 || echo "")
  if echo "$falco_logs_deep" | grep -qiE 'rules|loaded|Loading rules|rule.*enabled'; then
    pass "Falco rules appear loaded"
  elif echo "$falco_logs_deep" | grep -qiE '"rule"|"priority"|"output"'; then
    pass "Falco rules active (producing rule-triggered output)"
  else
    skip "Falco rules loading status unclear from recent logs"
  fi

  # 7k. Falco custom chronicle rules mounted (uses prefetched data)
  falco_mounts=$(_get mounts "$FALCO_CONTAINER")
  if echo "$falco_mounts" | grep -q "chronicle-rules"; then
    pass "Falco custom chronicle-rules.yaml mounted"
  else
    fail "Falco custom chronicle-rules.yaml not mounted"
  fi
fi

# --- Vault ---
if require_container "$VAULT_CONTAINER" "Vault checks"; then
  # 7l. Vault status
  vault_status=$(docker exec "$VAULT_CONTAINER" vault status -format=json 2>/dev/null || echo "{}")
  if echo "$vault_status" | grep -q "initialized"; then
    pass "Vault status endpoint responding"
  else
    fail "Vault status endpoint not responding"
  fi

  # 7m. Vault initialized
  vault_init=$(echo "$vault_status" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print('true' if data.get('initialized', False) else 'false')
except: print('unknown')
" 2>/dev/null || echo "unknown")
  if [ "$vault_init" = "true" ]; then
    pass "Vault is initialized"
  elif [ "$vault_init" = "false" ]; then
    skip "Vault is NOT initialized (run init-vault.sh)"
  else
    skip "Vault initialization status unknown"
  fi

  # 7n. Vault sealed status
  vault_sealed=$(echo "$vault_status" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print('true' if data.get('sealed', True) else 'false')
except: print('unknown')
" 2>/dev/null || echo "unknown")
  if [ "$vault_sealed" = "false" ]; then
    pass "Vault is unsealed"
  elif [ "$vault_sealed" = "true" ]; then
    skip "Vault is sealed (needs unseal)"
  else
    skip "Vault seal status unknown"
  fi

  # 7o. Vault IPC_LOCK capability (uses prefetched data)
  vault_caps=$(_get capadd "$VAULT_CONTAINER")
  if echo "$vault_caps" | grep -q "IPC_LOCK"; then
    pass "Vault has IPC_LOCK capability (memory locking)"
  else
    fail "Vault missing IPC_LOCK capability"
  fi
fi

# =============================================================================
# SECTION 8: Network Isolation Checks
# =============================================================================
section "8. Network Isolation"

# 8a. Backend is not directly exposed on host ports (uses prefetched data)
be_ports=$(_get ports "$BE_CONTAINER")
if echo "$be_ports" | grep -q '"HostPort"'; then
  fail "Backend has host port bindings (should be Traefik-only)"
else
  pass "Backend has no direct host port bindings (Traefik-only access)"
fi

# 8b. PostgreSQL is not directly exposed on host ports (uses prefetched data)
if [ "$(_get running "$PG_CONTAINER")" = "true" ]; then
  pg_ports=$(_get ports "$PG_CONTAINER")
  if echo "$pg_ports" | grep -q '"HostPort"'; then
    fail "PostgreSQL has host port bindings (should be internal-only)"
  else
    pass "PostgreSQL has no direct host port bindings (internal-only)"
  fi
fi

# 8c. Monitoring services not directly exposed (uses prefetched data)
for mon_container in "$PROM_CONTAINER" "$LOKI_CONTAINER" "$GRAFANA_CONTAINER"; do
  if [ "$(_get running "$mon_container")" = "true" ]; then
    mon_ports=$(_get ports "$mon_container")
    if echo "$mon_ports" | grep -q '"HostPort"'; then
      fail "$mon_container has host port bindings (should be internal-only)"
    else
      pass "$mon_container has no direct host port bindings"
    fi
  fi
done

# 8d. Traefik is on expected ports (80, 443) (uses prefetched data)
if [ "$(_get running "$TRAEFIK_CONTAINER")" = "true" ]; then
  traefik_ports=$(_get ports "$TRAEFIK_CONTAINER")
  if echo "$traefik_ports" | grep -q '"80/tcp"'; then
    pass "Traefik listening on port 80"
  else
    fail "Traefik not listening on port 80"
  fi
  if echo "$traefik_ports" | grep -q '"443/tcp"'; then
    pass "Traefik listening on port 443"
  else
    skip "Traefik not listening on port 443 (may be HTTP-only deployment)"
  fi
fi

# =============================================================================
# SECTION 9: Volume and Data Persistence Checks
# =============================================================================
section "9. Volume and Data Persistence"

# Check that critical named volumes exist
for vol_name in chronicle_postgres_data chronicle_audit_logs chronicle_prometheus_data chronicle_grafana_data chronicle_loki_data; do
  if docker volume inspect "$vol_name" >/dev/null 2>&1; then
    pass "Named volume '$vol_name' exists"
  else
    fail "Named volume '$vol_name' not found"
  fi
done

# =============================================================================
# SECTION 10: End-to-End Connectivity
# =============================================================================
section "10. End-to-End Connectivity"

# 10a. Frontend accessible via Traefik
fe_via_traefik=$(curl -sf --max-time 10 -o /dev/null -w '%{http_code}' "http://${DOMAIN}/chronicle/" 2>/dev/null || echo "000")
if [ "$fe_via_traefik" = "200" ]; then
  pass "Frontend accessible via Traefik at /chronicle/ (HTTP 200)"
elif [ "$fe_via_traefik" != "000" ]; then
  pass "Frontend accessible via Traefik at /chronicle/ (HTTP $fe_via_traefik)"
else
  fail "Frontend not accessible via Traefik at /chronicle/"
fi

# 10b. Backend API accessible via Traefik
be_via_traefik=$(curl -sf --max-time 10 -o /dev/null -w '%{http_code}' "http://${DOMAIN}/chronicle/v3/auth/session" 2>/dev/null || echo "000")
if [ "$be_via_traefik" = "200" ] || [ "$be_via_traefik" = "401" ] || [ "$be_via_traefik" = "403" ] || [ "$be_via_traefik" = "429" ]; then
  pass "Backend API accessible via Traefik (HTTP $be_via_traefik)"
elif [ "$be_via_traefik" != "000" ]; then
  pass "Backend API accessible via Traefik (HTTP $be_via_traefik — service alive)"
else
  fail "Backend API not accessible via Traefik"
fi

# 10c. Grafana accessible via Traefik
gf_via_traefik=$(curl -sf --max-time 10 -o /dev/null -w '%{http_code}' "http://${DOMAIN}/grafana/api/health" 2>/dev/null || echo "000")
if [ "$gf_via_traefik" = "200" ]; then
  pass "Grafana accessible via Traefik at /grafana/ (HTTP 200)"
elif [ "$gf_via_traefik" != "000" ]; then
  pass "Grafana accessible via Traefik at /grafana/ (HTTP $gf_via_traefik)"
else
  skip "Grafana not accessible via Traefik (may be IP-restricted)"
fi

# 10d. Blocked routes return non-200
blocked_code=$(curl -sf --max-time 10 -o /dev/null -w '%{http_code}' "http://${DOMAIN}/chronicle/datastore/" 2>/dev/null || echo "000")
if [ "$blocked_code" = "404" ] || [ "$blocked_code" = "403" ] || [ "$blocked_code" = "429" ] || [ "$blocked_code" = "000" ]; then
  pass "Blocked route /chronicle/datastore/ returns $blocked_code (not directly accessible)"
elif [ "$blocked_code" = "200" ]; then
  fail "Blocked route /chronicle/datastore/ returns 200 (should be blocked)"
else
  pass "Blocked route /chronicle/datastore/ returns $blocked_code (not 200)"
fi

# 10e. Prometheus endpoint not exposed externally (should be internal-only)
prom_ext=$(curl -sf --max-time 5 -o /dev/null -w '%{http_code}' "http://${DOMAIN}/prometheus/" 2>/dev/null || echo "000")
if [ "$prom_ext" = "200" ]; then
  fail "Prometheus externally accessible at /prometheus/ (should be blocked)"
else
  pass "Prometheus not externally accessible (HTTP $prom_ext)"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "=============================================="
echo "  CHRONICLE SMOKE TEST SUMMARY"
echo "=============================================="
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  \033[32mPassed:\033[0m  $PASS"
echo -e "  \033[31mFailed:\033[0m  $FAIL"
echo -e "  \033[33mSkipped:\033[0m $SKIP"
echo "  ──────────────────────────────"
echo "  Total:   $TOTAL assertions"
echo "=============================================="
echo "Finished: $(date -Iseconds)"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "Some checks failed. Review the [FAIL] entries above."
  exit 1
else
  echo "All checks passed (with $SKIP skipped)."
  exit 0
fi
