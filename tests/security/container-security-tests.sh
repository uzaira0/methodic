#!/usr/bin/env bash
# =============================================================================
# Chronicle Docker Container Runtime Security Audit
# =============================================================================
# Inspects running Chronicle containers for security misconfigurations:
#   - Non-root users, dropped capabilities, read-only filesystems
#   - Privilege escalation prevention, volume mount hygiene
#   - PID/network namespace isolation, memory limits
#
# Usage:
#   ./tests/security/container-security-tests.sh
#
# Requires: docker CLI access, Chronicle stack running (docker-compose -p chronicle)
# =============================================================================
set -euo pipefail

PASS=0
FAIL=0
WARN=0
SKIP=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
log()  { echo -e "\033[1;34m[AUDIT]\033[0m $*"; }
pass() { echo -e "  \033[1;32m[PASS]\033[0m $*"; PASS=$((PASS + 1)); }
fail() { echo -e "  \033[1;31m[FAIL]\033[0m $*"; FAIL=$((FAIL + 1)); }
warn() { echo -e "  \033[1;33m[WARN]\033[0m $*"; WARN=$((WARN + 1)); }
skip() { echo -e "  \033[1;33m[SKIP]\033[0m $*"; SKIP=$((SKIP + 1)); }
info() { echo -e "  \033[0;36m[INFO]\033[0m $*"; }

# ---------------------------------------------------------------------------
# Discover containers belonging to the chronicle compose project
# ---------------------------------------------------------------------------
COMPOSE_PROJECT="chronicle"

mapfile -t CONTAINERS < <(
  docker ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" \
    --format '{{.Names}}' 2>/dev/null
)

if [ "${#CONTAINERS[@]}" -eq 0 ]; then
  echo "No running containers found for compose project '${COMPOSE_PROJECT}'."
  echo "Start the stack first:  docker compose -p chronicle up -d"
  exit 1
fi

echo ""
log "Chronicle Container Runtime Security Audit"
log "Containers discovered: ${CONTAINERS[*]}"
echo ""

# Classify containers -------------------------------------------------------
APP_CONTAINERS=()
for c in "${CONTAINERS[@]}"; do
  case "$c" in
    *backend*|*frontend*) APP_CONTAINERS+=("$c") ;;
  esac
done

# Helper: check if a container name matches a pattern
is_app_container() {
  local name="$1"
  case "$name" in
    *backend*|*frontend*) return 0 ;;
  esac
  return 1
}

is_monitoring_container() {
  local name="$1"
  case "$name" in
    *prometheus*|*grafana*|*loki*|*promtail*|*falco*) return 0 ;;
  esac
  return 1
}

# =============================================================================
# Test 1: Non-Root User Audit
# =============================================================================
log "Test 1: Non-Root User Audit"
for container in "${CONTAINERS[@]}"; do
  if ! is_app_container "$container"; then
    continue
  fi
  user=$(docker inspect --format '{{.Config.User}}' "$container" 2>/dev/null || true)
  if [ -z "$user" ] || [ "$user" = "root" ] || [ "$user" = "0" ]; then
    fail "$container — runs as root or no user specified (User='${user:-<empty>}')"
  else
    pass "$container — runs as non-root user '${user}'"
  fi
done

# =============================================================================
# Test 2: Capability Audit
# =============================================================================
echo ""
log "Test 2: Linux Capability Audit"
for container in "${CONTAINERS[@]}"; do
  cap_add=$(docker inspect --format '{{.HostConfig.CapAdd}}' "$container" 2>/dev/null || true)
  # Normalize: docker returns [] or <nil> or [CAP1 CAP2]
  if [ -z "$cap_add" ] || [ "$cap_add" = "[]" ] || [ "$cap_add" = "<nil>" ]; then
    pass "$container — no added capabilities"
  else
    # Check exceptions
    case "$container" in
      *postgres*)
        info "$container — added capabilities: ${cap_add} (database — may be expected)"
        ;;
      *vault*)
        if echo "$cap_add" | grep -q "IPC_LOCK"; then
          pass "$container — IPC_LOCK capability (expected for Vault)"
        else
          warn "$container — unexpected capabilities: ${cap_add}"
        fi
        ;;
      *fail2ban*)
        if echo "$cap_add" | grep -qE "NET_ADMIN|NET_RAW"; then
          pass "$container — NET_ADMIN/NET_RAW capabilities (expected for fail2ban)"
        else
          warn "$container — unexpected capabilities: ${cap_add}"
        fi
        ;;
      *)
        if is_app_container "$container"; then
          fail "$container — has added capabilities: ${cap_add}"
        else
          warn "$container — has added capabilities: ${cap_add}"
        fi
        ;;
    esac
  fi
done

# =============================================================================
# Test 3: Read-Only Root Filesystem
# =============================================================================
echo ""
log "Test 3: Read-Only Root Filesystem"
for container in "${CONTAINERS[@]}"; do
  readonly_rootfs=$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$container" 2>/dev/null || true)
  if [ "$readonly_rootfs" = "true" ]; then
    pass "$container — read-only root filesystem"
  else
    info "$container — root filesystem is writable (consider enabling ReadonlyRootfs)"
  fi
done

# =============================================================================
# Test 4: No New Privileges
# =============================================================================
echo ""
log "Test 4: No New Privileges Flag"
for container in "${CONTAINERS[@]}"; do
  sec_opts=$(docker inspect --format '{{.HostConfig.SecurityOpt}}' "$container" 2>/dev/null || true)
  if echo "$sec_opts" | grep -qE "no-new-privileges(:true)?"; then
    pass "$container — no-new-privileges is set"
  else
    warn "$container — no-new-privileges not set (SecurityOpt='${sec_opts}')"
  fi
done

# =============================================================================
# Test 5: Volume Mount Audit
# =============================================================================
echo ""
log "Test 5: Volume Mount Audit"

SENSITIVE_PATHS=("/" "/etc" "/var/run/docker.sock")

for container in "${CONTAINERS[@]}"; do
  mounts_json=$(docker inspect --format '{{json .Mounts}}' "$container" 2>/dev/null || true)
  if [ -z "$mounts_json" ] || [ "$mounts_json" = "null" ] || [ "$mounts_json" = "[]" ]; then
    info "$container — no volume mounts"
    continue
  fi

  # Check for Docker socket mount
  has_docker_sock=false
  docker_sock_ro=false
  if echo "$mounts_json" | grep -q "docker.sock"; then
    has_docker_sock=true
    if echo "$mounts_json" | python3 -c "
import json, sys
mounts = json.load(sys.stdin)
for m in mounts:
    src = m.get('Source', '')
    if 'docker.sock' in src:
        if m.get('RW', True):
            sys.exit(1)
sys.exit(0)
" 2>/dev/null; then
      docker_sock_ro=true
    fi
  fi

  if $has_docker_sock; then
    if is_app_container "$container"; then
      fail "$container — Docker socket mounted in app container!"
    elif is_monitoring_container "$container"; then
      if $docker_sock_ro; then
        pass "$container — Docker socket mounted read-only (monitoring — acceptable)"
      else
        warn "$container — Docker socket mounted read-write in monitoring container"
      fi
    else
      warn "$container — Docker socket mounted"
    fi
  fi

  # Check for sensitive host path mounts that are writable
  for spath in "${SENSITIVE_PATHS[@]}"; do
    # Skip docker.sock (handled above)
    [ "$spath" = "/var/run/docker.sock" ] && continue

    echo "$mounts_json" | python3 -c "
import json, sys
mounts = json.load(sys.stdin)
target = '${spath}'
for m in mounts:
    src = m.get('Source', '')
    # Exact match for / or /etc (avoid matching /etc/ssl which is fine)
    if target == '/':
        if src == '/':
            rw = m.get('RW', True)
            if rw:
                print('WRITABLE_ROOT')
                sys.exit(0)
    elif src == target:
        rw = m.get('RW', True)
        if rw:
            print('WRITABLE')
            sys.exit(0)
" 2>/dev/null | while read -r result; do
      if [ "$result" = "WRITABLE_ROOT" ]; then
        fail "$container — host root (/) mounted writable!"
      elif [ "$result" = "WRITABLE" ]; then
        fail "$container — sensitive path '${spath}' mounted writable!"
      fi
    done
  done

  # If no issues found for this container, report pass
  if is_app_container "$container" && ! $has_docker_sock; then
    pass "$container — no Docker socket or dangerous host mounts"
  fi
done

# =============================================================================
# Test 6: PID Namespace Isolation
# =============================================================================
echo ""
log "Test 6: PID Namespace Isolation"
for container in "${CONTAINERS[@]}"; do
  pid_mode=$(docker inspect --format '{{.HostConfig.PidMode}}' "$container" 2>/dev/null || true)
  if [ "$pid_mode" = "host" ]; then
    if is_app_container "$container"; then
      fail "$container — uses host PID namespace"
    else
      warn "$container — uses host PID namespace"
    fi
  else
    pass "$container — PID namespace isolated (mode='${pid_mode:-default}')"
  fi
done

# =============================================================================
# Test 7: Network Mode
# =============================================================================
echo ""
log "Test 7: Network Mode"
for container in "${CONTAINERS[@]}"; do
  net_mode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$container" 2>/dev/null || true)
  if [ "$net_mode" = "host" ]; then
    case "$container" in
      *fail2ban*)
        pass "$container — host networking (expected for fail2ban)"
        ;;
      *)
        if is_app_container "$container"; then
          fail "$container — uses host networking"
        else
          warn "$container — uses host networking"
        fi
        ;;
    esac
  else
    pass "$container — network mode '${net_mode}'"
  fi
done

# =============================================================================
# Test 8: Memory Limits
# =============================================================================
echo ""
log "Test 8: Memory Limits"
for container in "${CONTAINERS[@]}"; do
  mem_limit=$(docker inspect --format '{{.HostConfig.Memory}}' "$container" 2>/dev/null || true)
  if [ -z "$mem_limit" ] || [ "$mem_limit" = "0" ]; then
    warn "$container — no memory limit set (unlimited)"
  else
    # Convert bytes to MB for readability
    mem_mb=$(( mem_limit / 1048576 ))
    pass "$container — memory limit set (${mem_mb} MB)"
  fi
done

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================================="
echo "  CONTAINER SECURITY AUDIT SUMMARY"
echo "=============================================="
echo -e "  \033[32mPassed:\033[0m  $PASS"
echo -e "  \033[31mFailed:\033[0m  $FAIL"
echo -e "  \033[33mWarned:\033[0m  $WARN"
echo -e "  \033[33mSkipped:\033[0m $SKIP"
echo "=============================================="
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "Review failed checks above and harden container configurations."
  exit 1
fi
