# Enrollment Blocker — Handoff

**Status**: blocked on Traefik routers redirecting every request to HTTPS.
**Date**: 2026-05-11
**Branch**: `develop` (1 file modified: `docker/docker-compose.traefik.yml`)

## Symptom

Mobile clients (Android Retrofit) cannot enroll. Every request to
`https://chronicle-screentime-app.research.bcm.edu/chronicle/v3/...` either
loops on redirects or 404s.

Reproduces locally against the running stack:

```bash
$ curl -i -H "Host: chronicle-screentime-app.research.bcm.edu" \
       http://localhost/chronicle/v3/study/anything
HTTP/1.1 301 Moved Permanently
Location: https://chronicle-screentime-app.research.bcm.edu/chronicle/v3/study/anything
```

Even a bogus Host header reproduces it (`Host: anything-else` → 301 to
`https://anything-else/...`). This means **Traefik itself is forcing the
redirect**, not the backend.

## Root Cause

`docker/docker-compose.traefik.yml` declares `tls=true` on three routers:

| Line | Router                  | `tls=true` |
|------|-------------------------|------------|
| 463  | `chronicle-mobile`      | yes        |
| 496  | `chronicle-web`         | yes        |
| 535  | `chronicle-block`       | yes        |

But the only Traefik entrypoint configured is plain HTTP `:80`:

```yaml
# docker/traefik/traefik.yml
entryPoints:
  web:
    address: :80
    # no `tls:` block
```

And `.env` sets `TRAEFIK_ENTRYPOINT=web`. F5 terminates client TLS at the VIP
and forwards plain HTTP to Traefik (see comments in `.env` and `traefik.yml`).

With `tls=true` on a router pinned to a plain-HTTP entrypoint, Traefik returns
`301 → https://...` for any matching request. F5 then forwards that response
to the client, breaking the mobile flow.

## Fix

Remove `tls=true` from the three routers. TLS is already terminated at the
F5 VIP; Traefik must serve the path-prefixed routes over plain HTTP on the
`web` entrypoint.

```diff
@@ chronicle-mobile router (line ~463)
       - "traefik.http.routers.chronicle-mobile.entrypoints=${TRAEFIK_ENTRYPOINT:-web}"
-      - "traefik.http.routers.chronicle-mobile.tls=true"

@@ chronicle-web router (line ~496)
       - "traefik.http.routers.chronicle-web.entrypoints=${TRAEFIK_ENTRYPOINT:-web}"
-      - "traefik.http.routers.chronicle-web.tls=true"

@@ chronicle-block router (line ~535)
       - "traefik.http.routers.chronicle-block.entrypoints=${TRAEFIK_ENTRYPOINT:-web}"
-      - "traefik.http.routers.chronicle-block.tls=true"
```

Then:

```bash
cd /home/opt/chronicle/docker
docker compose -f docker-compose.traefik.yml up -d traefik chronicle-backend
```

### Verify

```bash
# Should return 200 (or backend-level 401/404, not 301):
curl -i -H "Host: chronicle-screentime-app.research.bcm.edu" \
     http://localhost/chronicle/v3/study/foo

# Frontend root should serve the SPA, not 301:
curl -i -H "Host: chronicle-screentime-app.research.bcm.edu" \
     http://localhost/chronicle/
```

If both come back as non-301 (200 or backend-layer 4xx), enrollment should
work end-to-end. Then exercise enrollment from a real device against the F5
VIP.

## Related WIP in this branch

`docker/docker-compose.traefik.yml` (uncommitted): added `/chronicle/v4/` to
the `chronicle-mobile` router's `PathPrefix` rule to accommodate the new
mobile API version. Keep that change — it is independent of the TLS fix.

```diff
- (`/chronicle/v3/`) || PathPrefix(`/chronicle/v2/`) || ...
+ (`/chronicle/v4/`) || PathPrefix(`/chronicle/v3/`) || ...
```

## Things ruled out (so you don't re-investigate)

- **Backend** (`chronicle-backend`) is healthy. Scheduled jobs run cleanly,
  no stack traces in last 100 log lines.
- **Postgres** is healthy, replica folding fix already landed (`960168a`).
- **CrowdSec / WAF** is not the cause — the 301 fires *before* request body
  inspection, and a bogus Host produces the same 301.
- **Frontend container** healthy on `chronicle-frontend:8080`.
- **F5 routing** delivers the request to Traefik — confirmed by reproducing
  with `curl` directly against `localhost:80` with the production Host header.

## Open follow-ups (lower priority)

- Postgres replica + Loki distroless healthcheck fixes already in `960168a`.
- Production-readiness work in `HANDOFF.md` (separate doc, 10 issues).
- If we ever want Traefik to terminate TLS itself (e.g. for a non-F5
  environment), add a `websecure` entrypoint with `tls:` block and switch
  `TRAEFIK_ENTRYPOINT=websecure`. Until then, plain HTTP is correct.

## Files touched in this session

- `docker/docker-compose.traefik.yml` — added `/chronicle/v4/` prefix (keep).
- `docker/.env-backups/` — untracked, ignore.
