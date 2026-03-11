# Chronicle Deployment Matrix

Updated: 2026-03-11

Use this matrix to choose the correct Docker Compose entrypoint. The compose files are not interchangeable.

| Scenario | Primary compose file(s) | When to use it | Notes |
|----------|-------------------------|----------------|-------|
| Local legacy all-in-one dev stack | `docker-compose.yml` | Quick local stack with bundled nginx | Uses the older local nginx flow documented in [README.md](/opt/chronicle/docker/README.md). |
| Local Traefik-aligned stack | `docker-compose.traefik.yml` | Local/prod-like stack behind an existing Traefik network | This is the main repo-level quick start. Validate with `docker compose -f docker/docker-compose.traefik.yml config -q`. |
| Hardened Traefik overlay | `docker-compose.traefik.yml` + `docker-compose.security.yml` | When WAF, rate-limit overlays, or fail2ban/logging protections are required | See [security/README.md](/opt/chronicle/docker/security/README.md). |
| Production-style standalone reverse proxy | `docker-compose.prod.yml` | Environments using the built-in production nginx path instead of external Traefik | See [DEPLOYMENT.md](/opt/chronicle/docker/DEPLOYMENT.md). |
| Monitoring overlays | Base compose + `docker-compose.loki.yml` or `docker-compose.opensearch.yml` or `docker-compose.kafka.yml` | Add SIEM/monitoring components to an existing deployment | Do not treat these as standalone entrypoints. |

## Current Defaults

- The root [README.md](/opt/chronicle/README.md) assumes `docker-compose.traefik.yml`.
- Testing-only web auth may still rely on `docker/chronicle-config.json` or `generate-jwt.sh` to expose `/chronicle/config.json`.
- External-domain and SSO allowlists must now be configured explicitly; do not assume Auth0 defaults.

## Validation

```bash
docker compose -f docker/docker-compose.traefik.yml config -q
docker compose -f docker/docker-compose.yml config -q
docker compose -f docker/docker-compose.prod.yml config -q
```
