# Experimental public dashboard

This directory is **source-only scaffolding**, not a supported self-host deployment. The
release builder excludes all of `experimental/`.

The supported release keeps researcher routes on a private listener because its built-in
single-admin login cannot satisfy MFA and must not be internet-facing. A public dashboard
needs a reviewed multi-user authentication system, an authentication-enabled frontend,
automated realm/client bootstrap, upgrade tests, and end-to-end authorization/MFA tests.
Those pieces are not complete here.

The retained files are inputs for that future work:

- `mode-behind-proxy-public.yml` and `Caddyfile`: upstream TLS, public dashboard.
- `mode-own-tls-public.yml` and `Caddyfile.tls`: local TLS, public dashboard.
- `auth.yml`: incomplete Keycloak/OIDC scaffold.

Do not copy these files into a release bundle or describe their containers as supported.
Promotion requires moving a complete configuration back under `overlays/`, adding it to
`docs/DEPLOYMENT-COMPATIBILITY.md`, and making the compatibility test exercise it.
