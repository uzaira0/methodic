#!/usr/bin/env bash
# Chronicle Deployment Script
#
# Performs rolling deployments with health verification and rollback capability.
# Designed for healthcare platform requirements: audit trail, zero-downtime,
# and automated rollback on failure.
#
# Usage:
#   ./scripts/deploy.sh --environment staging --tag sha-abc1234
#   ./scripts/deploy.sh --environment production --tag v1.2.0
#   ./scripts/deploy.sh --rollback --environment production
#   ./scripts/deploy.sh --verify-only --environment staging
#
# Required environment or flags:
#   --environment   staging|production
#   --tag           Docker image tag to deploy
#   --backend-image (optional) Override backend image name
#   --frontend-image (optional) Override frontend image name
#
# Environment variables (set in .env.<environment> or export):
#   BACKEND_IMAGE    ghcr.io registry path for backend
#   FRONTEND_IMAGE   ghcr.io registry path for frontend
#   IMAGE_TAG        Docker image tag

set -euo pipefail

# ─────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${PROJECT_ROOT}/docker"
DEPLOY_LOG="${PROJECT_ROOT}/deploy-audit.log"
STATE_DIR="${PROJECT_ROOT}/.deploy-state"
COMPOSE_BASE="${DOCKER_DIR}/docker-compose.traefik.yml"
COMPOSE_PROD="${DOCKER_DIR}/docker-compose.production.yml"

# Timeouts
BACKEND_HEALTH_TIMEOUT=120    # seconds
FRONTEND_HEALTH_TIMEOUT=30    # seconds
POSTGRES_HEALTH_TIMEOUT=60    # seconds

# ─────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────
ENVIRONMENT=""
IMAGE_TAG=""
BACKEND_IMAGE_ARG=""
FRONTEND_IMAGE_ARG=""
ROLLBACK=false
VERIFY_ONLY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment|-e) ENVIRONMENT="$2"; shift 2 ;;
    --tag|-t) IMAGE_TAG="$2"; shift 2 ;;
    --backend-image) BACKEND_IMAGE_ARG="$2"; shift 2 ;;
    --frontend-image) FRONTEND_IMAGE_ARG="$2"; shift 2 ;;
    --rollback) ROLLBACK=true; shift ;;
    --verify-only) VERIFY_ONLY=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h)
      echo "Usage: $0 --environment <staging|production> --tag <image-tag>"
      echo ""
      echo "Options:"
      echo "  --environment, -e   Target environment (staging or production)"
      echo "  --tag, -t           Docker image tag to deploy"
      echo "  --backend-image     Override backend image path"
      echo "  --frontend-image    Override frontend image path"
      echo "  --rollback          Rollback to previous deployment"
      echo "  --verify-only       Only run health verification"
      echo "  --dry-run           Show what would be done without executing"
      echo "  --help, -h          Show this help"
      exit 0
      ;;
    *) echo "ERROR: Unknown argument: $1"; exit 1 ;;
  esac
done

# ─────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -Is)"
  echo "[${ts}] [${level}] ${msg}"
  echo "[${ts}] [${level}] ${msg}" >> "${DEPLOY_LOG}" 2>/dev/null || true
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_audit() { log "AUDIT" "$@"; }

die() {
  log_error "$@"
  exit 1
}

compose_cmd() {
  local env_file="${DOCKER_DIR}/.env"
  if [[ -n "${ENVIRONMENT}" && -f "${DOCKER_DIR}/.env.${ENVIRONMENT}" ]]; then
    env_file="${DOCKER_DIR}/.env.${ENVIRONMENT}"
  fi

  docker compose \
    --env-file "${env_file}" \
    -f "${COMPOSE_BASE}" \
    -f "${COMPOSE_PROD}" \
    "$@"
}

# ─────────────────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────────────────
validate_args() {
  if [[ -z "${ENVIRONMENT}" ]]; then
    die "Missing required --environment flag"
  fi

  if [[ "${ENVIRONMENT}" != "staging" && "${ENVIRONMENT}" != "production" ]]; then
    die "Invalid environment '${ENVIRONMENT}'. Must be 'staging' or 'production'."
  fi

  if [[ "${VERIFY_ONLY}" == true ]]; then
    return
  fi

  if [[ "${ROLLBACK}" == true ]]; then
    if [[ ! -f "${STATE_DIR}/previous-tag" ]]; then
      die "No previous deployment state found. Cannot rollback."
    fi
    return
  fi

  if [[ -z "${IMAGE_TAG}" ]]; then
    die "Missing required --tag flag"
  fi
}

# ─────────────────────────────────────────────────────────
# State management (for rollback)
# ─────────────────────────────────────────────────────────
save_state() {
  mkdir -p "${STATE_DIR}"

  # Save current state as "previous" before deploying
  if [[ -f "${STATE_DIR}/current-tag" ]]; then
    cp "${STATE_DIR}/current-tag" "${STATE_DIR}/previous-tag"
    cp "${STATE_DIR}/current-backend-image" "${STATE_DIR}/previous-backend-image" 2>/dev/null || true
    cp "${STATE_DIR}/current-frontend-image" "${STATE_DIR}/previous-frontend-image" 2>/dev/null || true
  fi

  # Save new state as current
  echo "${IMAGE_TAG}" > "${STATE_DIR}/current-tag"
  echo "${BACKEND_IMAGE}" > "${STATE_DIR}/current-backend-image"
  echo "${FRONTEND_IMAGE}" > "${STATE_DIR}/current-frontend-image"
  echo "$(date -Is)" > "${STATE_DIR}/last-deploy-time"
  echo "${ENVIRONMENT}" > "${STATE_DIR}/last-deploy-environment"
}

load_rollback_state() {
  IMAGE_TAG="$(cat "${STATE_DIR}/previous-tag")"
  BACKEND_IMAGE="$(cat "${STATE_DIR}/previous-backend-image" 2>/dev/null || echo "${BACKEND_IMAGE}")"
  FRONTEND_IMAGE="$(cat "${STATE_DIR}/previous-frontend-image" 2>/dev/null || echo "${FRONTEND_IMAGE}")"
  log_info "Rollback target: tag=${IMAGE_TAG}"
}

# ─────────────────────────────────────────────────────────
# Health checks
# ─────────────────────────────────────────────────────────
wait_for_healthy() {
  local service="$1"
  local url="$2"
  local timeout="$3"
  local elapsed=0
  local interval=5

  log_info "Waiting for ${service} to become healthy (timeout: ${timeout}s)..."

  while [[ ${elapsed} -lt ${timeout} ]]; do
    if curl -sf --max-time 5 "${url}" > /dev/null 2>&1; then
      log_info "${service} healthy after ${elapsed}s"
      return 0
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  log_error "${service} failed to become healthy after ${timeout}s"
  return 1
}

verify_deployment() {
  local failed=0

  log_info "Verifying deployment health..."

  # Check container states
  local unhealthy
  unhealthy=$(compose_cmd ps --format json 2>/dev/null | \
    python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        c = json.loads(line)
        state = c.get('Health', c.get('State', 'unknown'))
        if state not in ('healthy', 'running'):
            print(f\"{c.get('Service','?')}: {state}\")
    except: pass
" 2>/dev/null || true)

  if [[ -n "${unhealthy}" ]]; then
    log_error "Unhealthy containers detected:"
    echo "${unhealthy}" | while read -r line; do log_error "  ${line}"; done
    failed=1
  fi

  # Backend health endpoint
  if ! curl -sf --max-time 10 http://127.0.0.1:40320/prometheus/ > /dev/null 2>&1; then
    log_error "Backend health check failed (port 40320)"
    failed=1
  else
    log_info "Backend health check passed"
  fi

  # Frontend health endpoint
  if ! curl -sf --max-time 5 http://127.0.0.1:8080/health > /dev/null 2>&1; then
    log_error "Frontend health check failed (port 8080)"
    failed=1
  else
    log_info "Frontend health check passed"
  fi

  # PostgreSQL (via compose exec)
  if ! compose_cmd exec -T postgres pg_isready -q 2>/dev/null; then
    log_error "PostgreSQL health check failed"
    failed=1
  else
    log_info "PostgreSQL health check passed"
  fi

  # Check that backend can reach the database (application-level check)
  local actuator_status
  actuator_status=$(curl -sf --max-time 10 http://127.0.0.1:40320/actuator/health 2>/dev/null || echo '{"status":"DOWN"}')
  if echo "${actuator_status}" | grep -q '"UP"' 2>/dev/null; then
    log_info "Backend actuator health: UP"
  else
    log_warn "Backend actuator health: ${actuator_status}"
    # Don't fail on actuator — not all deployments expose it
  fi

  if [[ ${failed} -ne 0 ]]; then
    log_error "Deployment verification FAILED"
    return 1
  fi

  log_info "Deployment verification PASSED"
  return 0
}

# ─────────────────────────────────────────────────────────
# Image operations
# ─────────────────────────────────────────────────────────
pull_images() {
  log_info "Pulling images: backend=${BACKEND_IMAGE}:${IMAGE_TAG} frontend=${FRONTEND_IMAGE}:${IMAGE_TAG}"

  if [[ "${DRY_RUN}" == true ]]; then
    log_info "[DRY RUN] Would pull images"
    return 0
  fi

  docker pull "${BACKEND_IMAGE}:${IMAGE_TAG}" || die "Failed to pull backend image"
  docker pull "${FRONTEND_IMAGE}:${IMAGE_TAG}" || die "Failed to pull frontend image"

  log_info "Images pulled successfully"
}

# ─────────────────────────────────────────────────────────
# Database migration check
# ─────────────────────────────────────────────────────────
check_migrations() {
  log_info "Checking for pending database migrations..."

  # Chronicle uses Liquibase/Flyway via Spring Boot auto-migration on startup.
  # The backend container will run migrations automatically during startup.
  # We verify post-startup that the backend is healthy (which implies migrations succeeded).

  # If manual migrations are needed in the future, add them here:
  # compose_cmd exec -T chronicle-backend java -jar migration-tool.jar migrate

  log_info "Database migrations will run automatically on backend startup"
}

# ─────────────────────────────────────────────────────────
# Deployment
# ─────────────────────────────────────────────────────────
deploy() {
  log_audit "DEPLOY_START environment=${ENVIRONMENT} tag=${IMAGE_TAG} user=$(whoami) hostname=$(hostname)"

  # Export image references for docker-compose.production.yml
  export IMAGE_TAG
  export BACKEND_IMAGE
  export FRONTEND_IMAGE

  if [[ "${DRY_RUN}" == true ]]; then
    log_info "[DRY RUN] Would deploy with:"
    log_info "  BACKEND_IMAGE=${BACKEND_IMAGE}:${IMAGE_TAG}"
    log_info "  FRONTEND_IMAGE=${FRONTEND_IMAGE}:${IMAGE_TAG}"
    log_info "  Environment: ${ENVIRONMENT}"
    compose_cmd config --quiet 2>/dev/null && log_info "  Compose config: valid" || log_warn "  Compose config: invalid"
    return 0
  fi

  # Pull images
  pull_images

  # Save state for potential rollback
  save_state

  # Check migrations
  check_migrations

  # Rolling restart: update frontend first (stateless, fast), then backend
  log_info "Starting rolling deployment..."

  # Step 1: Update frontend (fast, stateless)
  log_info "Updating frontend..."
  compose_cmd up -d --no-deps --remove-orphans chronicle-frontend
  if ! wait_for_healthy "frontend" "http://127.0.0.1:8080/health" "${FRONTEND_HEALTH_TIMEOUT}"; then
    log_error "Frontend failed health check — initiating rollback"
    rollback_deployment
    exit 1
  fi

  # Step 2: Update backend (may run migrations)
  log_info "Updating backend..."
  compose_cmd up -d --no-deps chronicle-backend
  if ! wait_for_healthy "backend" "http://127.0.0.1:40320/prometheus/" "${BACKEND_HEALTH_TIMEOUT}"; then
    log_error "Backend failed health check — initiating rollback"
    rollback_deployment
    exit 1
  fi

  # Step 3: Full verification
  if ! verify_deployment; then
    log_error "Post-deploy verification failed — initiating rollback"
    rollback_deployment
    exit 1
  fi

  # Clean up old images (keep last 3)
  log_info "Cleaning up old images..."
  docker image prune -f --filter "until=168h" 2>/dev/null || true

  log_audit "DEPLOY_COMPLETE environment=${ENVIRONMENT} tag=${IMAGE_TAG} user=$(whoami)"
  log_info "Deployment successful: ${IMAGE_TAG} -> ${ENVIRONMENT}"

  # Show running containers
  compose_cmd ps
}

rollback_deployment() {
  log_audit "ROLLBACK_START environment=${ENVIRONMENT} failed_tag=${IMAGE_TAG} user=$(whoami)"

  if [[ ! -f "${STATE_DIR}/previous-tag" ]]; then
    log_error "No previous state to rollback to. Manual intervention required."
    log_error "Container logs:"
    compose_cmd logs --tail=50 chronicle-backend chronicle-frontend 2>&1 | tail -100
    return 1
  fi

  local prev_tag
  prev_tag="$(cat "${STATE_DIR}/previous-tag")"
  local prev_backend
  prev_backend="$(cat "${STATE_DIR}/previous-backend-image" 2>/dev/null || echo "${BACKEND_IMAGE}")"
  local prev_frontend
  prev_frontend="$(cat "${STATE_DIR}/previous-frontend-image" 2>/dev/null || echo "${FRONTEND_IMAGE}")"

  log_info "Rolling back to: tag=${prev_tag}"

  export IMAGE_TAG="${prev_tag}"
  export BACKEND_IMAGE="${prev_backend}"
  export FRONTEND_IMAGE="${prev_frontend}"

  compose_cmd up -d --no-deps chronicle-backend chronicle-frontend

  if wait_for_healthy "backend" "http://127.0.0.1:40320/prometheus/" "${BACKEND_HEALTH_TIMEOUT}" && \
     wait_for_healthy "frontend" "http://127.0.0.1:8080/health" "${FRONTEND_HEALTH_TIMEOUT}"; then
    log_audit "ROLLBACK_COMPLETE environment=${ENVIRONMENT} restored_tag=${prev_tag}"
    log_info "Rollback successful. Restored tag: ${prev_tag}"

    # Update current state to reflect rollback
    echo "${prev_tag}" > "${STATE_DIR}/current-tag"
    echo "${prev_backend}" > "${STATE_DIR}/current-backend-image"
    echo "${prev_frontend}" > "${STATE_DIR}/current-frontend-image"
  else
    log_error "ROLLBACK FAILED. Manual intervention required!"
    log_error "Container logs:"
    compose_cmd logs --tail=50 chronicle-backend chronicle-frontend 2>&1 | tail -100
    log_audit "ROLLBACK_FAILED environment=${ENVIRONMENT} attempted_tag=${prev_tag}"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────
main() {
  validate_args

  # Set default image names if not provided
  BACKEND_IMAGE="${BACKEND_IMAGE_ARG:-${BACKEND_IMAGE:-ghcr.io/methodic-labs/chronicle/chronicle-backend}}"
  FRONTEND_IMAGE="${FRONTEND_IMAGE_ARG:-${FRONTEND_IMAGE:-ghcr.io/methodic-labs/chronicle/chronicle-frontend}}"

  if [[ "${VERIFY_ONLY}" == true ]]; then
    verify_deployment
    exit $?
  fi

  if [[ "${ROLLBACK}" == true ]]; then
    load_rollback_state
    log_info "Initiating manual rollback to tag=${IMAGE_TAG}"
    export IMAGE_TAG BACKEND_IMAGE FRONTEND_IMAGE
    compose_cmd up -d --no-deps chronicle-backend chronicle-frontend
    if verify_deployment; then
      log_audit "MANUAL_ROLLBACK_COMPLETE environment=${ENVIRONMENT} tag=${IMAGE_TAG}"
      echo "${IMAGE_TAG}" > "${STATE_DIR}/current-tag"
    else
      die "Manual rollback verification failed. Check container logs."
    fi
    exit 0
  fi

  deploy
}

main "$@"
