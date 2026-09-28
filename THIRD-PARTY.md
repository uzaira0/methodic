# Licenses of shipped components

The self-host scripts and configuration in this repository are under the Apache License 2.0
(`LICENSE`). The container images a deployment runs carry their own licenses.

## Chronicle images

| Image | License | Source |
|---|---|---|
| `ghcr.io/uzaira0/chronicle-backend` | GPL-3.0 | https://github.com/uzaira0/chronicle-server |
| `ghcr.io/uzaira0/chronicle-selfhost-frontend` | GPL-3.0 | https://github.com/uzaira0/chronicle-web |
| `ghcr.io/uzaira0/chronicle-selfhost-caddy` | Apache-2.0 (Caddy and its plugins) | https://github.com/caddyserver/caddy, built by `selfhost/Dockerfile.caddy` |

Each Chronicle image is built from the commit recorded in `release-manifest.json` as
`public_revision`: a commit of https://github.com/uzaira0/methodic (the release tag points at
it) whose submodules pin the exact `chronicle-server` and `chronicle-web` source.

## Third-party images

Pulled unmodified by digest from their publishers. Licenses are the upstream projects'.

| Image | Used by | Upstream |
|---|---|---|
| Percona Distribution for PostgreSQL (`POSTGRES_IMAGE`) | database | https://github.com/percona/postgres |
| `prodrigestivill/postgres-backup-local` | backups overlay | https://github.com/prodrigestivill/docker-postgres-backup-local |
| `grafana/grafana` (AGPL-3.0) | monitoring overlay | https://github.com/grafana/grafana |
| `victoriametrics/victoria-metrics`, `victoriametrics/victoria-logs` | monitoring overlay | https://github.com/VictoriaMetrics/VictoriaMetrics |
| `fluent/fluent-bit` | monitoring overlay | https://github.com/fluent/fluent-bit |
| `ghcr.io/google/cadvisor` | monitoring overlay | https://github.com/google/cadvisor |
| `tecnativa/docker-socket-proxy` | monitoring overlay | https://github.com/Tecnativa/docker-socket-proxy |
