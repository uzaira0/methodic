# Chronicle Deployment Matrix

Updated: 2026-04-06

Use this matrix to choose the correct Docker Compose entrypoint. The compose files are not interchangeable.

| Scenario | Primary compose file(s) | When to use it | Notes |
|----------|-------------------------|----------------|-------|
| Local legacy all-in-one dev stack | `docker-compose.yml` | Quick local stack with bundled nginx | Uses the older local nginx flow documented in [README.md](/opt/chronicle/docker/README.md). |
| Local Traefik-aligned stack | `docker-compose.traefik.yml` | Local/prod-like stack behind an existing Traefik network | This is the main repo-level quick start. Validate with `docker compose -f docker/docker-compose.traefik.yml config -q`. |
| Hardened Traefik overlay | `docker-compose.traefik.yml` + `docker-compose.security.yml` | When WAF, rate-limit overlays, or fail2ban/logging protections are required | See [security/README.md](/opt/chronicle/docker/security/README.md). |
| Legacy standalone reverse proxy | `docker-compose.prod.yml` with `--profile legacy-standalone` | Historical nginx-based stack only; not the active production path | Prefer `docker-compose.traefik.yml` plus `docker-compose.production.yml` through `scripts/deploy.sh`, or the `prod-backend` branch workflow for backend-only deploys. |
| Monitoring/event overlays | Base compose + `docker-compose.loki.yml` or `docker-compose.opensearch.yml` or `docker-compose.kafka.yml` | Add SIEM, log search, or event-streaming components to an existing deployment | Do not treat these as standalone entrypoints. Kafka requires `KAFKA_CLUSTER_ID`, `KAFKA_USER`, and `KAFKA_PASSWORD` in an untracked env file. |
| Temporal workflows | Base compose + `docker-compose.temporal.yml` | Add durable workflow engine for notifications, upload pipelines, scheduled ops | Requires base PostgreSQL. Admin tools via `--profile tools`. |
| RHEL 9 dedicated server | `docker-compose.traefik.yml` + `docker-compose.production.yml` or `k8s/overlays/production` | Internal dedicated host migration | Start with [docs/RHEL9-DEDICATED-SERVER-RUNBOOK.md](../docs/RHEL9-DEDICATED-SERVER-RUNBOOK.md). A 4-core/8 GB host is constrained; do not colocate the full monitoring/SSO/WAF stack there. |

## Current Defaults

- The root [README.md](/opt/chronicle/README.md) assumes `docker-compose.traefik.yml`.
- The active web auth path uses `/chronicle/v3/auth/session` plus
  `/chronicle/v3/auth/testing-login` in test-friendly environments.
- `docker/chronicle-config.json` is only a manual-diagnostics artifact produced by
  `generate-jwt.sh`; it is not deployed by default and is not part of the active
  runtime contract.
- External-domain and SSO allowlists must now be configured explicitly; do not assume Auth0 defaults.

## Validation

```bash
docker compose -f docker/docker-compose.traefik.yml config -q
docker compose -f docker/docker-compose.yml config -q
docker compose -f docker/docker-compose.prod.yml --profile legacy-standalone config -q
docker compose -f docker/docker-compose.traefik.yml -f docker/docker-compose.temporal.yml config -q
```
