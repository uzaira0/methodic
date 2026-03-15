#!/usr/bin/env bash
# =============================================================================
# Chronicle Incident Response Readiness Drill
# =============================================================================
# Validates that all monitoring, logging, backup, and recovery systems are
# operational and ready to support incident response.
#
# Usage:
#   ./tests/security/ir-drill-checklist.sh
#
# Exit codes:
#   0 — all critical checks passed
#   1 — one or more critical checks failed
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
BOLD="\033[1m"
RESET="\033[0m"

PASS=0
FAIL=0
WARN=0
TOTAL=0
CRITICAL_FAIL=0

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

ready() {
  echo -e "  $(timestamp)  ${GREEN}READY${RESET}     $*"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
}

not_ready() {
  echo -e "  $(timestamp)  ${RED}NOT-READY${RESET} $*"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  CRITICAL_FAIL=$((CRITICAL_FAIL + 1))
}

warn() {
  echo -e "  $(timestamp)  ${YELLOW}WARN${RESET}      $*"
  WARN=$((WARN + 1))
  TOTAL=$((TOTAL + 1))
}

info() {
  echo -e "  $(timestamp)  ${BLUE}INFO${RESET}      $*"
}

separator() {
  echo ""
  echo -e "${BOLD}--- $* ---${RESET}"
}

# =============================================================================
echo ""
echo -e "${BOLD}=============================================="
echo "  CHRONICLE INCIDENT RESPONSE READINESS DRILL"
echo -e "==============================================${RESET}"
echo "  Started: $(timestamp)"
echo ""

# =============================================================================
# Check 1: Loki Reachable
# Critical for audit trail during incidents
# =============================================================================
separator "Check 1: Loki Reachable"
info "Loki provides centralized audit log aggregation."
info "During an incident, Loki is the primary source for audit trail queries."

LOKI_RESPONSE=$(curl -s --max-time 5 http://localhost:3100/ready 2>/dev/null || echo "UNREACHABLE")
if echo "$LOKI_RESPONSE" | grep -qi "ready"; then
  ready "Loki is reachable and ready (http://localhost:3100)"
else
  not_ready "Loki is NOT reachable — audit trail unavailable (response: $LOKI_RESPONSE)"
fi

# =============================================================================
# Check 2: Audit Log Query
# During an incident, use this endpoint to search audit events
# =============================================================================
separator "Check 2: Audit Log Query via Loki"
info "Sample LogQL query: {job=\"audit_logs\"}"
info "During an incident, query Loki directly for rapid audit event search:"
info "  curl 'http://localhost:3100/loki/api/v1/query?query={job=\"audit_logs\"}&limit=100'"

AUDIT_RESPONSE=$(curl -s --max-time 10 'http://localhost:3100/loki/api/v1/query?query={job="audit_logs"}&limit=5' 2>/dev/null || echo "QUERY_FAILED")
if echo "$AUDIT_RESPONSE" | grep -q '"status":"success"'; then
  RESULT_COUNT=$(echo "$AUDIT_RESPONSE" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    results = data.get('data', {}).get('result', [])
    print(len(results))
except:
    print(0)
" 2>/dev/null || echo "0")
  if [ "$RESULT_COUNT" -gt 0 ]; then
    ready "Audit log query returned $RESULT_COUNT stream(s) — audit events present"
  else
    warn "Audit log query succeeded but returned 0 results — no recent audit events"
  fi
else
  not_ready "Audit log query failed — cannot search audit events during incident"
fi

# =============================================================================
# Check 3: Prometheus Metrics Available
# During incident: check HikariPool metrics for DB connection exhaustion
# =============================================================================
separator "Check 3: Prometheus Metrics Available"
info "During an incident, check Prometheus for resource exhaustion:"
info "  HikariPool_1_pool_ActiveConnections — DB connection pool saturation"
info "  HikariPool_1_pool_PendingConnections — requests waiting for a connection"
info "  Query UI: http://localhost:9090/graph"

TARGETS_RESPONSE=$(curl -s --max-time 5 http://localhost:9090/api/v1/targets 2>/dev/null || echo "UNREACHABLE")
if echo "$TARGETS_RESPONSE" | grep -q '"status":"success"'; then
  BACKEND_UP=$(echo "$TARGETS_RESPONSE" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    targets = data.get('data', {}).get('activeTargets', [])
    up = [t for t in targets if t.get('health') == 'up']
    print(len(up))
except:
    print(0)
" 2>/dev/null || echo "0")
  if [ "$BACKEND_UP" -gt 0 ]; then
    ready "Prometheus reachable — $BACKEND_UP target(s) reporting 'up'"
  else
    warn "Prometheus reachable but no targets are 'up' — metrics may be stale"
  fi
else
  not_ready "Prometheus is NOT reachable at http://localhost:9090"
fi

# =============================================================================
# Check 4: Grafana Accessible
# Dashboard URLs for incident triage
# =============================================================================
separator "Check 4: Grafana Accessible"
info "Incident triage dashboards:"
info "  Backend overview:  http://localhost:3000/d/chronicle-backend"
info "  Audit log viewer:  http://localhost:3000/d/chronicle-audit"
info "  Via Traefik:       https://<host>/grafana"

GRAFANA_HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:3000/api/health 2>/dev/null || echo "000")
if [ "$GRAFANA_HTTP" = "200" ]; then
  ready "Grafana is accessible (HTTP 200)"
else
  not_ready "Grafana is NOT accessible (HTTP $GRAFANA_HTTP) — dashboards unavailable for triage"
fi

# =============================================================================
# Check 5: Backup Recency
# During incident: this determines RPO (Recovery Point Objective)
# =============================================================================
separator "Check 5: Backup Recency (RPO Assessment)"
BACKUP_DIR="/opt/chronicle/backups"
info "Backup directory: $BACKUP_DIR"
info "During an incident, the most recent backup determines your Recovery Point Objective."
info "Restore procedure: docker/restore-chronicle.sh"

if [ -d "$BACKUP_DIR" ]; then
  LATEST_BACKUP=$(find "$BACKUP_DIR" -maxdepth 1 -name "*.sql.gz.enc" -o -name "*.sql.gz" -o -name "*.dump" -o -name "*.dump.enc" 2>/dev/null | \
    xargs -r ls -t 2>/dev/null | head -1)
  if [ -n "$LATEST_BACKUP" ]; then
    BACKUP_AGE_SECS=$(( $(date +%s) - $(stat -c %Y "$LATEST_BACKUP") ))
    BACKUP_AGE_HOURS=$(( BACKUP_AGE_SECS / 3600 ))
    BACKUP_NAME=$(basename "$LATEST_BACKUP")
    if [ "$BACKUP_AGE_HOURS" -lt 48 ]; then
      ready "Latest backup is ${BACKUP_AGE_HOURS}h old: $BACKUP_NAME (RPO < 48h)"
    else
      BACKUP_AGE_DAYS=$(( BACKUP_AGE_HOURS / 24 ))
      warn "Latest backup is ${BACKUP_AGE_DAYS} days old: $BACKUP_NAME — RPO exceeds 48h!"
    fi
  else
    not_ready "No backup files found in $BACKUP_DIR — RPO is undefined!"
  fi
else
  not_ready "Backup directory $BACKUP_DIR does not exist!"
fi

# =============================================================================
# Check 6: Credential Rotation Capability
# During incident: rotate JWT immediately if compromise suspected
# =============================================================================
separator "Check 6: Credential Rotation Capability"
info "If credential compromise is suspected during an incident:"
info "  1. Rotate JWT:  cd docker && ./generate-jwt.sh --write-config"
info "  2. Restart frontend to pick up new token"
info "  3. Rotate DB password: update .env, ALTER USER in postgres, restart backend"

JWT_SCRIPT="$PROJECT_ROOT/docker/generate-jwt.sh"
if [ -f "$JWT_SCRIPT" ]; then
  if [ -x "$JWT_SCRIPT" ]; then
    # Dry-run: check the script can at least parse (bash -n)
    if bash -n "$JWT_SCRIPT" 2>/dev/null; then
      ready "generate-jwt.sh exists, is executable, and parses correctly"
    else
      warn "generate-jwt.sh exists but has syntax errors — rotation may fail"
    fi
  else
    warn "generate-jwt.sh exists but is NOT executable — run: chmod +x $JWT_SCRIPT"
  fi
else
  not_ready "generate-jwt.sh not found at $JWT_SCRIPT — cannot rotate credentials!"
fi

# =============================================================================
# Check 7: Container Health
# =============================================================================
separator "Check 7: Container Health"
info "All Chronicle containers should be running and healthy."

CONTAINER_OUTPUT=$(docker ps --filter "label=com.docker.compose.project=chronicle" --format '{{.Names}}\t{{.Status}}' 2>/dev/null || echo "DOCKER_ERROR")
if [ "$CONTAINER_OUTPUT" = "DOCKER_ERROR" ]; then
  not_ready "Cannot connect to Docker daemon"
elif [ -z "$CONTAINER_OUTPUT" ]; then
  not_ready "No Chronicle containers found — stack may not be running"
else
  UNHEALTHY=0
  CONTAINER_COUNT=0
  while IFS=$'\t' read -r name status; do
    CONTAINER_COUNT=$((CONTAINER_COUNT + 1))
    if echo "$status" | grep -qi "unhealthy"; then
      info "  $name: ${RED}$status${RESET}"
      UNHEALTHY=$((UNHEALTHY + 1))
    elif echo "$status" | grep -qi "up"; then
      info "  $name: ${GREEN}$status${RESET}"
    else
      info "  $name: ${YELLOW}$status${RESET}"
      UNHEALTHY=$((UNHEALTHY + 1))
    fi
  done <<< "$CONTAINER_OUTPUT"

  if [ "$UNHEALTHY" -eq 0 ]; then
    ready "All $CONTAINER_COUNT Chronicle containers are running"
  else
    not_ready "$UNHEALTHY of $CONTAINER_COUNT containers are unhealthy or not running"
  fi
fi

# =============================================================================
# Check 8: Database Connectivity
# =============================================================================
separator "Check 8: Database Connectivity"
info "PostgreSQL must be accepting connections for the application to function."

DB_READY=$(docker exec chronicle-postgres pg_isready -U chronicle 2>/dev/null || echo "UNREACHABLE")
if echo "$DB_READY" | grep -qi "accepting connections"; then
  ready "PostgreSQL is accepting connections"
else
  not_ready "PostgreSQL is NOT accepting connections: $DB_READY"
fi

# =============================================================================
# Check 9: Alerting Channel (Informational)
# =============================================================================
separator "Check 9: Alerting Channel"
info "Incident response contacts and procedures:"
info "  1. Check Grafana dashboards for immediate triage"
info "  2. Query Loki for audit trail"
info "  3. File incident report per organizational policy"
info ""

ENV_FILE="$PROJECT_ROOT/docker/.env"
if [ -f "$ENV_FILE" ]; then
  SMTP_STATUS=$(grep -E '^SMTP_ENABLED=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "not set")
  if [ "$SMTP_STATUS" = "true" ]; then
    ready "SMTP is configured and enabled — email alerting available"
  else
    warn "SMTP is NOT enabled (SMTP_ENABLED=$SMTP_STATUS) — no email alerting"
    info "  To enable: set SMTP_ENABLED=true in docker/.env and restart backend"
  fi
else
  warn "docker/.env not found — cannot verify SMTP configuration"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BOLD}=============================================="
echo "  INCIDENT RESPONSE READINESS SUMMARY"
echo -e "==============================================${RESET}"
echo "  Completed: $(timestamp)"
echo ""
echo -e "  ${GREEN}READY:${RESET}     $PASS"
echo -e "  ${RED}NOT-READY:${RESET} $FAIL"
echo -e "  ${YELLOW}WARN:${RESET}      $WARN"
echo ""
echo -e "  ${BOLD}Readiness Score: $PASS/$TOTAL checks passed${RESET}"
echo ""

if [ "$CRITICAL_FAIL" -gt 0 ]; then
  echo -e "  ${RED}${BOLD}RESULT: NOT READY — $CRITICAL_FAIL critical check(s) failed.${RESET}"
  echo -e "  ${RED}Address NOT-READY items before relying on incident response tooling.${RESET}"
  echo ""
  exit 1
else
  if [ "$WARN" -gt 0 ]; then
    echo -e "  ${YELLOW}${BOLD}RESULT: READY (with $WARN warning(s))${RESET}"
    echo -e "  ${YELLOW}Review WARN items to improve incident response posture.${RESET}"
  else
    echo -e "  ${GREEN}${BOLD}RESULT: READY — all checks passed.${RESET}"
  fi
  echo ""
  exit 0
fi
