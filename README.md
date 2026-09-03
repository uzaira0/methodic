# Chronicle

Research data collection platform for longitudinal studies, supporting Android sensor data, iOS sensor data, time-use diaries, and questionnaire surveys.

## Run your own instance

`selfhost/` is a self-contained deployment of the same server, meant for a team running
Chronicle on their own hardware. Three commands, from nothing to a working dashboard:

```bash
git clone https://github.com/uzaira0/methodic.git chronicle
cd chronicle/selfhost
./chronicle setup     # asks a handful of questions and writes .env
./chronicle up        # builds the images, starts the stack, initialises the database
./chronicle verify    # proves the deployment actually works end to end
```

`setup` asks how the deployment is reached — behind an existing load balancer, terminating
its own TLS, or issuing a local certificate for phones on the same network — then which
addresses to listen on and a dashboard password. Everything else has a default.

The first `up` builds the backend and frontend from source and initialises the database, so
it takes considerably longer than later runs. There is no output while the database settles;
that is expected.

Then open `https://<your-dashboard-address>/chronicle/` and sign in as `researcher`.

Other commands: `status`, `logs`, `doctor`, `restore`, `upgrade`, `rotate-secret`,
`monitoring`, `down`. Run the stack through this script rather than `docker compose`
directly: in a source clone the script initializes the required submodules, builds and pins
the local images, and runs host checks that Compose cannot perform.

See [`selfhost/README.md`](selfhost/README.md) for the full reference: backups, encryption
at rest, upgrades, and what each deployment mode assumes.

## Architecture

| Component | Technology | Location |
|-----------|-----------|----------|
| Backend API | Java 25 (bytecode target 21) / Kotlin / Spring / Gradle | `chronicle-server/` |
| API models | Kotlin DTOs with Bean Validation | `chronicle-api/` |
| Web frontend | React | `chronicle-web/` |
| Android app | Kotlin | `chronicle/` |
| Shared libraries | Rhizome framework | `rhizome/`, `rhizome-client/` |
| Database | PostgreSQL 18 (Percona, pg_tde) | via Docker |
| Monitoring | VictoriaMetrics + VictoriaLogs + Grafana | `docker/monitoring/` |
| Reverse proxy | Traefik | `docker/` and Kubernetes deployment manifests |

## Submodules

This is a Gradle multi-project that uses git submodules:

- **chronicle** — Android data collection app
- **chronicle-api** — shared API models and DTOs
- **chronicle-server** — backend REST API server
- **chronicle-web** — React web dashboard
- **rhizome** — core framework (DB, auth, mail)
- **rhizome-client** — shared client utilities

`selfhost/` checks out the ones it needs on first run. To clone them all up front:

```bash
git clone --recurse-submodules https://github.com/uzaira0/methodic.git
```

## Development Setup

**Prerequisites:** JDK 25 (Temurin; Android submodule uses JDK 21), Bun 1.3.x, Gradle (wrapper included)

```bash
# Backend
./gradlew build

# Frontend
cd chronicle-web
bun install
bun run dev
```

## Larger deployments

The compose files under `docker/` are the multi-host deployment path, with Traefik,
Keycloak, monitoring and the security stack as separate concerns:

```bash
cp docker/.env.example docker/.env      # fill in POSTGRES_PASSWORD, JWT_SECRET, …
docker compose -p <your-project-name> -f docker/docker-compose.traefik.yml up -d
```

Pick a project name of your own. Compose keys volumes off it, so reusing another
deployment's name adopts that deployment's database.

See [`docker/DEPLOYMENT-MATRIX.md`](docker/DEPLOYMENT-MATRIX.md) for which compose path
fits your situation, and [`docker/DEPLOYMENT.md`](docker/DEPLOYMENT.md) for the full
instructions.

## Continuous integration

All checks run locally; there are no hosted workflows. `lefthook` runs the fast gates on
commit and push, and `scripts/local-ci.sh` runs the full matrix on demand:

```bash
scripts/local-ci.sh fast        # preflight, web, JVM smoke, repo guardrails, schema drift
scripts/local-ci.sh security    # dependency, SAST, secrets and container scans
scripts/local-ci.sh --help      # every job and group
```

Public history is curated from the private repositories with `make publish-stage` and
`make publish-push`; see [docs/GIT-WORKFLOW.md](docs/GIT-WORKFLOW.md) for the model.

## License

See [LICENSE](LICENSE).
