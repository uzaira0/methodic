# Chronicle Hetzner Security Exceptions

## CVE-2026-54369 — `libacl`

- Status: temporary, bounded exception
- Reviewed: 2026-07-19
- Affected runtime: `localhost/chronicle-percona:17.10-hardened`
- Installed package: `libacl-2.3.1-4.el9.x86_64`
- Scanner result: HIGH, with no fixed package offered by the current image
  repository at review time

The affected library is present in the PostgreSQL container, but Chronicle
does not accept ACL files or extended-attribute payloads from clients. The
database has no host-published port, is reachable only from the fixed backend
address on its private Podman network, runs with a read-only root filesystem,
`no-new-privileges`, a reduced capability set, memory and PID limits, and
encrypted database volumes. Public requests terminate at Tailscale Funnel and
then pass through the loopback-only Traefik/CrowdSec edge before reaching the
backend; they cannot address PostgreSQL directly.

Remove this exception as soon as the Percona/RHEL image repository supplies a
fixed `libacl`. The update must rebuild the pinned Percona image, rerun the
HIGH/CRITICAL container scan, update the exact allowed image ID in the NixOS
policy, pass the isolated backup restore drill, and pass `verify-stack.sh`
before deployment.
