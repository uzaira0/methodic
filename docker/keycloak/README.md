# Chronicle Keycloak Broker

Chronicle can use Keycloak as an optional local OIDC broker. Chronicle validates
only Keycloak-issued OIDC tokens; each self-hosting operator owns the upstream
identity-provider registration and configuration.

## Configuration

Start the broker after copying the tracked environment example to an untracked
operator environment file and replacing every placeholder:

```bash
docker compose -f docker-compose.traefik.yml --profile sso up -d keycloak
```

The public example values use reserved domains:

- Public base URL: `https://chronicle.example.com/keycloak`
- Realm: `chronicle`
- Client: `chronicle-web`
- Redirect URI: `https://chronicle.example.com/chronicle/v3/auth/oidc/callback`
- Upstream provider: `upstream-oidc`

Configure `UPSTREAM_OIDC_CLIENT_ID`, `UPSTREAM_OIDC_CLIENT_SECRET`,
`UPSTREAM_OIDC_ISSUER`, `UPSTREAM_OIDC_AUTH_URL`,
`UPSTREAM_OIDC_TOKEN_URL`, `UPSTREAM_OIDC_USERINFO_URL`, and
`UPSTREAM_OIDC_JWKS_URL` from the operator's OIDC provider. The public
repository intentionally contains no institution endpoint, client credential,
metadata document, or signing certificate.

The realm includes a disabled `upstream-saml` example containing reserved
example URLs and a replacement certificate marker. It is not a supported
production login path. Production startup rejects selecting it while MFA
assurance mapping is unavailable.

## MFA contract

The upstream OIDC broker imports `amr` with `syncMode: FORCE`, and the
Chronicle client emits it in access tokens. Before setting
`CHRONICLE_SECURITY_MFA_IDP_PROOF_VERIFIED=true`, verify with redacted test
tokens that the provider emits current-session assurance on every login.
Chronicle accepts explicit `amr=mfa`, `pwd` plus a possession factor, or an
operator-approved `acr`. A possession marker alone is insufficient.

Keep `CHRONICLE_SECURITY_MFA_IDP_PROOF_VERIFIED=false` until both MFA and
non-MFA sessions have been tested. Backend and Keycloak startup fail closed
when production MFA proof is absent.

## Runtime isolation

- Keycloak uses a dedicated Postgres service and volume.
- Keycloak does not join the Chronicle application database network.
- Traefik reaches Keycloak only over `chronicle-sso-edge`.
- Chronicle backend reaches Keycloak only over `chronicle-sso-broker`.
- Keycloak reaches its database only over `chronicle-sso-db`.
- Keycloak runs without root, drops all capabilities, enables
  `no-new-privileges`, uses a read-only root filesystem, and mounts `/tmp`
  as tmpfs.

Run the static guardrail with:

```bash
mkdir -p .local/reports/sso
tests/security/run-all-security.sh sso .local/reports/sso
```
