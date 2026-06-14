# W4 — Encryption in Transit / Transport Hardening (HIPAA §164.312(e)(1))

**Workstream:** HIPAA-2028 Compliance Lane — W4 (encryption at rest/in transit, key management)
**Control:** HIPAA Security Rule §164.312(e)(1) — *Transmission security.*
**Status:** Staged and documented; **mTLS on the Traefik↔backend bridge is OFF by default.**
This artifact makes the transport-hardening control documented and discoverable and ships
ready-to-enable config; it does **not** change the live transport path.
See the lane design: `docs/superpowers/specs/2026-06-13-hipaa-2028-compliance-lane-design.md` (§79–83).

---

## 1. Control mapping

The HIPAA Security Rule's transmission-security standard is §164.312(e)(1). Under the
January-2025 NPRM (the overhaul targeting ~2028 compliance), encryption of ePHI **in transit**
moves from an *addressable* to a **required** implementation specification. Chronicle's
in-transit posture has two internal hops behind the F5 TLS-terminating VIP; this artifact
covers the **Traefik → chronicle-backend** hop on the internal `chronicle-backend-bridge`.

| Hop | Today | W4 target |
|---|---|---|
| Client → F5 VIP (`chronicle-screentime-app.research.bcm.edu`) | TLS (F5 terminates) | unchanged |
| F5 → Traefik (`:80`) | plaintext, RFC1918 intranet, `X-Forwarded-Proto=https` trusted | unchanged (out of W4 scope) |
| Traefik → chronicle-backend (`chronicle-backend-bridge`, `internal: true`) | **plain HTTP, port 40320** | **mTLS to 8443** (staged, this artifact) |
| chronicle-backend → PostgreSQL | TLS, `sslmode=require` (env-default), `scram-sha-256` | **`sslmode=verify-full`** — pinned in the JDBC URL + IaC-guarded (see §6) |

The Traefik→backend hop runs on a Docker bridge with `internal: true` (no outbound internet,
backend isolated from sibling app containers). Upgrading it to mTLS adds defense-in-depth:
mutual authentication of both proxy and backend, plus encryption of the last internal hop —
so the only plaintext segment left is the RFC1918 F5→Traefik link.

---

## 2. What is shipped (staged, inert)

The mTLS config is present and loadable but bound to nothing — exactly like the W3 MFA flag
that ships off until the IdP is ready.

| Artifact | Path | State |
|---|---|---|
| serversTransport definition | `docker/traefik/dynamic/servers-transport.yml` | Loaded by Traefik's file provider; **referenced by no service** → never instantiated |
| Enablement labels (service → https + transport bind) | `docker/docker-compose.traefik.yml`, `chronicle-backend` service labels | **Commented out**; active label stays `...loadbalancer.server.port=40320` |
| Cert material | `/etc/traefik/certs/{client.crt,client.key,ca.crt}` | **Not mounted**; placeholder paths only |

**Why this is inert:** a Traefik `serversTransport` changes nothing until a router's *service*
binds to it via `loadbalancer.serversTransport`. The active `chronicle-backend` service targets
plain HTTP on 40320; the lines that would switch it to https/8443 + bind
`chronicle-backend-mtls@file` are commented out in the compose labels. Defining the transport
does not alter the live transport path.

---

## 3. The serversTransport

`docker/traefik/dynamic/servers-transport.yml` defines `http.serversTransports.chronicle-backend-mtls`:

- **`rootCAs: [/etc/traefik/certs/ca.crt]`** — CA used to verify the backend's **server**
  certificate (the connection is no longer trusted blindly).
- **`certificates: [{certFile: client.crt, keyFile: client.key}]`** — the **client**
  certificate Traefik presents to the backend (the "mutual" half).
- **`serverName: chronicle-backend`** — expected SAN/CN on the backend cert (the service name
  Traefik dials on the bridge); adjust if the issued cert differs.
- **`insecureSkipVerify: false`** — verification stays on; disabling it would defeat the upgrade.

---

## 4. Backend-side change required (chronicle-server `jetty.yaml`)

mTLS is a **two-sided** change. Traefik presenting a client cert is meaningless unless the
backend (a) terminates TLS and (b) **requires** that client cert. The backend's `jetty.yaml`
is **not modified by this artifact** — these are the settings an operator must apply on the
backend side at enable time.

| Setting | Today | W4 target | Why |
|---|---|---|---|
| `https-port` | `8443` | `8443` | TLS listener (already present) |
| `use-ssl` | `true` | `true` | TLS enabled (already present) |
| `require-ssl` | `false` | **`true`** | Reject plaintext — force the TLS listener |
| `require-client-auth` | `false` | **`true`** | **Demand** Traefik's client cert (the mutual half) |
| `want-client-auth` | `false` | `false`/n/a | `require-client-auth` supersedes the optional "want" |
| `certificate-alias` | `rhizomessl` | server keypair alias | Backend's own server cert presented to Traefik |

Today the backend **actively serves plain HTTP on 40320** (the port Traefik targets) and,
although `use-ssl` is true, `require-ssl` and `require-client-auth` are both `false`. So even
with the listener up, it would not enforce client auth. Flipping `require-ssl: true` +
`require-client-auth: true` and pointing Traefik at 8443 is the cutover.

---

## 5. How to enable in production

mTLS is **off by default** and must stay off until both sides + certs are ready. Enable in
this order (one-sided changes break the hop):

1. **Issue certs.** Produce a CA, a backend **server** cert (SAN = `chronicle-backend`), and a
   Traefik **client** cert, all chaining to that CA.
2. **Backend first.** Apply the §4 `jetty.yaml` settings (`require-ssl: true`,
   `require-client-auth: true`, `https-port: 8443`, server keypair in the keystore) and roll
   the backend so it terminates TLS + demands a client cert on 8443.
3. **Mount certs into Traefik.** Add to the `traefik` service `volumes:` in
   `docker/docker-compose.traefik.yml`:
   `- ./traefik/certs:/etc/traefik/certs:ro,z`, and place `client.crt`, `client.key`, `ca.crt`
   there (paths match `servers-transport.yml`).
4. **Flip Traefik.** In the `chronicle-backend` service labels, uncomment the three staged
   lines (service → port 8443, scheme https, `serversTransport=chronicle-backend-mtls@file`)
   and comment out — do **not** delete — the active `...server.port=40320` line.
5. **Validate end-to-end.** `docker compose -f docker/docker-compose.traefik.yml up -d`,
   confirm Traefik dials the backend over https with the client cert (backend accepts), and
   confirm a connection **without** the client cert is rejected by the backend.

> **Outage warning.** Flipping Traefik to https/8443 **before** the backend terminates TLS
> with `require-client-auth: true` — or before the certs are mounted — breaks the entire
> Traefik→backend hop (every API route 502s). Sequence: certs → backend → Traefik labels.
> Until all three are done, leave the staged labels commented and the active 40320 line live.

---

## 6. PostgreSQL connection — sslmode pinned to verify-full

The backend→PostgreSQL hop was already TLS, but `sslmode` came from the `POSTGRES_SSL_MODE`
env var (default `require` — encrypts but does **not** verify the server cert or hostname,
leaving it open to an active MITM presenting any cert). W4 pins the strongest mode directly in
the JDBC URL:

- **`docker/rhizome-docker.yaml.template`** — both `jdbcUrl`s hardcode
  `sslmode=verify-full&sslrootcert=/app/ssl/ca.crt` (verifies the server cert chains to the
  mounted CA **and** that its SAN covers the `postgres` hostname). No longer env-overridable,
  so a deploy cannot silently downgrade the connection.
- **`docker/.env.example`, `.env.staging`, both compose files** — `POSTGRES_SSL_MODE` default
  aligned to `verify-full` (now vestigial for the URL, kept coherent + self-documenting).
- **IaC guard:** `tests/security/policies/docker_compose.rego` denies any compose service whose
  `POSTGRES_SSL_MODE` resolves to a weaker mode (disable/allow/prefer/require/verify-ca);
  `conftest` fails the build on a downgrade. Verified passing on both compose files.

**Precondition:** verify-full requires the postgres server certificate's SAN to include the
`postgres` service hostname and to be signed by the CA at `/app/ssl/ca.crt`. Issue a conforming
cert before rolling, or the backend will refuse the connection.

## 7. Source pointers

- **serversTransport (dynamic config):** `docker/traefik/dynamic/servers-transport.yml`
- **Staged enablement labels (commented):** `docker/docker-compose.traefik.yml` —
  `chronicle-backend` service, immediately below
  `traefik.http.services.chronicle-backend.loadbalancer.server.port=40320`.
- **File provider that loads the transport:** `docker/traefik/traefik.yml` —
  `providers.file.directory: /etc/traefik/dynamic` (`watch: true`).
- **Backend TLS listener config (NOT modified here):** chronicle-server `jetty.yaml`
  (`https-port`, `use-ssl`, `require-ssl`, `require-client-auth`, `certificate-alias`).
- **Bridge network definition:** `docker/docker-compose.traefik.yml` — `networks.chronicle-backend-bridge` (`internal: true`).
- **sslmode pin (JDBC URL):** `docker/rhizome-docker.yaml.template` — both `jdbcUrl`s, `sslmode=verify-full`.
- **sslmode IaC guard:** `tests/security/policies/docker_compose.rego` — `POSTGRES_SSL_MODE` weak-mode deny rule.
