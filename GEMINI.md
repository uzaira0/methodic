# Chronicle Project Context

Research data collection platform for longitudinal studies, supporting Android/iOS sensor data, time-use diaries, and questionnaire surveys.

## Project Overview

Chronicle is a multi-component system designed for secure, HIPAA-compliant research data collection. It is structured as a Gradle multi-project with git submodules.

### Architecture & Tech Stack
- **Backend API (`chronicle-server`):** Java 17/21, Spring Boot, Gradle.
- **API Models (`chronicle-api`):** Kotlin DTOs with Bean Validation.
- **Web Frontend (`chronicle-web`):** React 19, Bun, TypeScript (migrating from Flow), Tailwind CSS, Radix UI, Zustand.
- **Android App (`chronicle`):** Kotlin-based data collection app.
- **Shared Libraries (`rhizome`, `rhizome-client`):** Core framework for DB, auth, and mail.
- **Database:** PostgreSQL 17 with `pg_tde` (Transparent Data Encryption) for at-rest encryption.
- **Infrastructure:** Docker Compose, Traefik/Nginx, HashiCorp Vault (for TDE keys), Prometheus/Grafana/Loki for monitoring.

---

## Development Workflows

### Prerequisites
- **JDK 17/21**
- **Bun** (Primary frontend runtime)
- **Node.js** (Legacy frontend support)
- **Gradle** (Wrapper included)
- **Docker & Docker Compose**

### Common Commands

| Task | Command |
|------|---------|
| **Backend Build** | `./gradlew build` |
| **Backend Tests** | `./gradlew test` |
| **Frontend Install** | `cd chronicle-web && bun install` |
| **Frontend Dev** | `cd chronicle-web && bun run modern:dev` |
| **Frontend Quality Check** | `cd chronicle-web && bun run check` |
| **Frontend Build** | `cd chronicle-web && bun run modern:build` |
| **Preflight Audit** | `./scripts/chronicle-preflight.sh` |
| **Full Validation** | `./scripts/chronicle-production-like-validation.sh` |
| **Docker (Dev)** | `docker compose -p chronicle -f docker/docker-compose.traefik.yml up -d` |

---

## Repository Structure & Rules

### Repo Shape
- **Submodules:** `chronicle-api`, `chronicle-server`, `rhizome`, `rhizome-client` are managed by the root Gradle build.
- **Web App:** `chronicle-web` is a nested git repository and uses Bun for package management and testing.
- **Android:** `chronicle` is operationally separate; use its own `gradlew`.
- **Infrastructure:** `docker/` contains multiple compose variants and security overlays.

### High-Signal Guidelines for Agents
- **Validation Matrix:** Never declare a task finished without running the relevant validation scripts (e.g., `./scripts/chronicle-smoke.sh`, `bun run check`).
- **Security First:** The project is HIPAA-compliant. Never compromise TDE, route isolation, or credential handling.
- **Auth Migration:** The project is moving from localStorage JWTs to backend-managed httpOnly cookies and institutional SSO.
- **Frontend Migration:** Actively retiring Redux/Immutable/Saga in favor of modern React patterns (Zustand, Hooks).
- **API Changes:** Changes in `chronicle-api` are cross-project and may affect server, web, and mobile components.
- **Silent Failure Hunter:** Run `./scripts/silent-failure-hunter.sh` during audits to catch regressions.

---

## Deployment & Security

- **Route Isolation:**
  - `/api/mobile/*`: Requires `X-Chronicle-App-Key`, strict rate limits.
  - `/api/web/*`: Requires JWT/Cookie auth.
  - `/chronicle/*`: Blocked by default (404).
- **Encryption:** `pg_tde` is required for PHI data. In production, keys are managed via HashiCorp Vault.
- **SSO:** Moving toward institutional SSO; avoid hardcoding Auth0-specific logic.

## Key Documentation
- `README.md`: Project overview.
- `AGENTS.md`: Detailed instructions for AI agents (Mandatory reading for complex tasks).
- `docker/DEPLOYMENT.md`: Production setup and architecture.
- `WORKFLOWS.md`: Submodule and release management.
