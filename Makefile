# Chronicle Makefile — performance testing targets
#
# Prerequisites:
#   - k6 installed (https://k6.io/docs/get-started/installation/)
#   - Docker Compose stack running (see: make perf-up)
#   - JWT token exported (see: make perf-token)

BASE_URL ?= http://127.0.0.1:40320
JWT_TOKEN ?=
STUDY_ID ?=
MAX_VUS ?= 200

# ---------------------------------------------------------------------------
# Docker Compose helpers
# ---------------------------------------------------------------------------

.PHONY: perf-up perf-down perf-token

## Start the Chronicle backend + Postgres via Docker Compose
perf-up:
	cd docker && docker compose -p chronicle -f docker-compose.traefik.yml up -d chronicle-backend chronicle-postgres
	@echo "Waiting for backend to be healthy..."
	@timeout 120 bash -c 'until curl -sf http://127.0.0.1:40320/actuator/health >/dev/null 2>&1; do sleep 2; done' || echo "WARN: health check timed out"
	@echo "Backend is up at $(BASE_URL)"

## Stop the Docker Compose stack and remove volumes
perf-down:
	cd docker && docker compose -p chronicle -f docker-compose.traefik.yml down -v

## Generate a JWT token for testing (requires docker/.env with JWT_SECRET)
perf-token:
	@cd docker && bash generate-jwt.sh

# ---------------------------------------------------------------------------
# Performance tests
# ---------------------------------------------------------------------------

.PHONY: perf-smoke perf-load perf-stress

## Smoke test — 1 VU, 10s, health + basic reads (CI-safe)
perf-smoke:
	k6 run \
		--env BASE_URL=$(BASE_URL) \
		--env JWT_TOKEN=$(JWT_TOKEN) \
		tests/performance/smoke.js

## Load test — 50 VUs, 30s, read + write endpoints
perf-load:
	k6 run \
		--env BASE_URL=$(BASE_URL) \
		--env JWT_TOKEN=$(JWT_TOKEN) \
		--env STUDY_ID=$(STUDY_ID) \
		tests/performance/load.js

## Stress test — ramp to 200+ VUs, find breaking points
perf-stress:
	k6 run \
		--env BASE_URL=$(BASE_URL) \
		--env JWT_TOKEN=$(JWT_TOKEN) \
		--env STUDY_ID=$(STUDY_ID) \
		--env MAX_VUS=$(MAX_VUS) \
		tests/performance/stress.js

# ---------------------------------------------------------------------------
# Aliases
# ---------------------------------------------------------------------------

.PHONY: help

## Show this help
help:
	@echo "Chronicle Performance Testing"
	@echo ""
	@echo "Docker:"
	@echo "  make perf-up       Start Chronicle backend via Docker Compose"
	@echo "  make perf-down     Stop and clean up Docker Compose stack"
	@echo "  make perf-token    Generate a JWT token for testing"
	@echo ""
	@echo "Tests:"
	@echo "  make perf-smoke    Smoke test (1 VU, 10s) — safe for CI"
	@echo "  make perf-load     Load test (50 VUs, 30s) — staging"
	@echo "  make perf-stress   Stress test (200 VUs, 5min) — manual"
	@echo ""
	@echo "Variables:"
	@echo "  BASE_URL=$(BASE_URL)"
	@echo "  JWT_TOKEN=<set via env or make perf-token>"
	@echo "  STUDY_ID=<uuid for write tests>"
	@echo "  MAX_VUS=$(MAX_VUS)"
