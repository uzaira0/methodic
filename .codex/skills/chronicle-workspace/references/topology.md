# Chronicle Topology

## Component Map

- `chronicle-server/`: Kotlin/Java backend on Spring/Rhizome.
- `chronicle-api/`: shared DTOs and Retrofit interfaces used by server tests and Android.
- `chronicle-web/`: React 18 + Flow web dashboard with Jest.
- `chronicle/`: Android app with its own Gradle wrapper.
- `rhizome/`, `rhizome-client/`: shared framework libraries.
- `docker/`: local/prod compose files, SSL/TLS helpers, monitoring, SIEM, and deployment assets.

## Validation Map

- Root project listing: `./gradlew projects`
- API tests: `./gradlew :chronicle-api:test`
- Web policy typecheck: `cd chronicle-web && npm run typecheck`
- Web combined check: `cd chronicle-web && npm run check`
- Web tests: `cd chronicle-web && npm test -- --runInBand --watch=false`
- Android build: `cd chronicle && ./gradlew assembleDebug`
- Traefik compose validation: `docker compose -f docker/docker-compose.traefik.yml config -q`
- Silent failure scan: `./scripts/silent-failure-hunter.sh`

## Stable Gotchas

- Root Gradle excludes the Android app.
- The web app is older React/Flow infrastructure, not TypeScript/Vite.
- Docker has multiple deployment paths; choose one intentionally.
- Some Gradle builds still use remote `apply from` scripts.
