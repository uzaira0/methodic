# Chronicle

Research data collection platform for longitudinal studies, supporting Android sensor data, iOS sensor data, time-use diaries, and questionnaire surveys.

## Architecture

| Component | Technology | Location |
|-----------|-----------|----------|
| Backend API | Java 17 / Spring / Gradle | `chronicle-server/` |
| API models | Kotlin DTOs with Bean Validation | `chronicle-api/` |
| Web frontend | React | `chronicle-web/` |
| Android app | Kotlin | `chronicle/` |
| Shared libraries | Rhizome framework | `rhizome/`, `rhizome-client/` |
| Database | PostgreSQL 17 (Percona, pg_tde) | via Docker |
| Monitoring | Prometheus + Grafana + Loki | `docker/monitoring/` |
| Reverse proxy | Traefik | external (dokploy-traefik) |

## Submodules

This is a Gradle multi-project that uses git submodules:

- **chronicle** — Android data collection app
- **chronicle-api** — shared API models and DTOs
- **chronicle-server** — backend REST API server
- **chronicle-web** — React web dashboard
- **rhizome** — core framework (DB, auth, mail)
- **rhizome-client** — shared client utilities

Clone with submodules:

```bash
git clone --recurse-submodules git@github.com:uzaira0/chronicle.git
```

## Quick Start (Docker Compose)

1. Copy the environment template and fill in secrets:

   ```bash
   cp docker/.env.example docker/.env
   # Edit docker/.env with your POSTGRES_PASSWORD, JWT_SECRET, etc.
   ```

2. Start all services:

   ```bash
   docker compose -p chronicle -f docker/docker-compose.traefik.yml up -d
   ```

3. If the deployment is using the temporary local testing-login bridge, verify
   it from the backend instead of relying on `/chronicle/config.json`:

   ```bash
   curl -s -X POST http://localhost/chronicle/v3/auth/testing-login \
     -H 'Content-Type: application/json' \
     -d '{}'
   ```

   For manual JWT diagnostics only, `cd docker && bash generate-jwt.sh` still
   prints a signed token that can be POSTed to `/chronicle/v3/auth/set-cookie`.

See [`docker/DEPLOYMENT-MATRIX.md`](docker/DEPLOYMENT-MATRIX.md) for which compose path to use, and [`docker/DEPLOYMENT.md`](docker/DEPLOYMENT.md) for full production instructions.

## Development Setup

**Prerequisites:** JDK 17, Bun, Node.js, Gradle (wrapper included)

```bash
# Backend
./gradlew build

# Frontend
cd chronicle-web
bun install
bun run modern:dev
```

## Production-Like Validation

Until institutional SSO is available, the closest production-style validation
lane is still based on the current session/testing-login bridge plus the full
web and server smoke path:

```bash
./scripts/chronicle-production-like-validation.sh
```

Notes:
- This validates the Traefik compose path, web checks/tests/browser smoke,
  route-cutover behavior, SSO drift, and the server auth smoke when Java is
  available.
- If the checked-out repo has an unwritable `.gradle` directory, set
  `CHRONICLE_GRADLE_PROJECT_CACHE_DIR` and `GRADLE_USER_HOME` to writable
  locations before running the script.

## CI/CD Workflows

| Workflow | File | Purpose |
|----------|------|---------|
| Build | `.github/workflows/build.yaml` | Gradle build + publish on push to develop/main |
| Security Scan | `.github/workflows/security-scan.yml` | OWASP dependency check, npm audit, Trivy container scan |

## License

See [LICENSE](LICENSE).

## AI Disclaimer

This application was developed with the assistance of artificial intelligence tools including Claude, ChatGPT, Copilot, Gemini, and Jules.
