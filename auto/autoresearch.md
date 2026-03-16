# Autoresearch: Chronicle Multi-Target Optimization

## Objective
Simultaneously optimize all measurable metrics. The agent runs an autonomous experiment loop: edit → commit → benchmark → keep/discard. Each change is validated before benchmarking. Changes that regress any metric are reverted immediately.

## Metrics
- **total_pass** (checks, ↑) — security test assertions passing
- **total_fail** (checks, ↓ to 0) — must stay at 0
- **total_skip** (checks, ↓) — convert skips to passes
- **bundle_kb** (KB, ↓) — frontend bundle size
- **backend_image_mb** (MB, ↓) — backend Docker image size
- **frontend_image_mb** (MB, ↓) — frontend Docker image size
- **heap_mb** (MB, ↓) — backend memory usage
- **api_p95_ms** (ms, ↓) — API p95 response time
- **backup_ms** (ms, ↓) — backup duration

## How to Run
`./auto/autoresearch.sh` — runs all benchmarks, outputs `METRIC name=number` lines.

## Files in Scope
- `tests/security/*.sh` — test scripts (increase pass count, reduce skips)
- `tests/load/*.js` — k6 tests
- `docker/Dockerfile.backend` — image size, build layers
- `docker/Dockerfile.frontend.prod` — image size, build layers
- `docker/docker-compose.traefik.yml` — memory limits, config
- `docker/nginx.frontend.conf` — caching, compression
- `chronicle-web/src/` — bundle size (dead code, imports)
- `docker/backup-chronicle.sh` — backup speed

## Off Limits
- Don't change application logic (controllers, services, authorization)
- Don't remove security controls to speed things up
- Don't change API contracts
- Don't modify .env secrets

## Constraints
- total_fail MUST stay at 0
- All containers must remain healthy
- Tests must be deterministic
- Bundle must still function correctly

## Strategic Direction
1. **Test passes**: fix promtail connectivity check, provide study data for business logic tests, fix contract drift spec gaps
2. **Bundle size**: tree-shake unused imports, lazy-load routes, analyze with `bun run build --report`
3. **Image size**: multi-stage builds are already used; check for leftover build artifacts, unnecessary apt packages
4. **Memory**: check Hazelcast cache sizes, JVM GC settings
5. **API latency**: database query optimization, connection pooling
6. **Backup speed**: parallel compression, exclude unnecessary files

## Baseline
- **total_pass**: 357
- **total_fail**: 21
- **total_skip**: 42
- **bundle_kb**: TBD
- **backend_image_mb**: TBD
- **frontend_image_mb**: TBD

## What's Been Tried
(none yet — first iteration)

## Current Best
(updated by the loop)
