# Chronicle Keycloak Broker

Chronicle uses Keycloak as the local OIDC broker. Chronicle should only know
about Keycloak OIDC; BCM SAML, InCommon/eduGAIN, or OpenAthens Keystone should
be attached to Keycloak as identity providers.

## Current Local Broker

- Public base URL: `https://chronicle-screentime-app.research.bcm.edu/keycloak`
- Realm: `chronicle`
- Client: `chronicle-web`
- Redirect URI: `https://chronicle-screentime-app.research.bcm.edu/chronicle/v3/auth/oidc/callback`
- Chronicle login endpoint: `/chronicle/v3/auth/oidc/login`

Start or update the broker:

```bash
docker compose -f docker-compose.traefik.yml --profile sso up -d keycloak
```

## Runtime Isolation

The SSO broker is intentionally separated from the main Chronicle application
runtime:

- Keycloak uses a dedicated Postgres service and volume.
- Keycloak does not join the main `chronicle-internal` app database network.
- Traefik reaches Keycloak only over `chronicle-sso-edge`.
- Chronicle backend reaches Keycloak only over `chronicle-sso-broker`.
- Keycloak reaches its database only over `chronicle-sso-db`.
- Keycloak runs as UID `1000`, drops all Linux capabilities, sets
  `no-new-privileges`, uses a read-only root filesystem, and has a tmpfs `/tmp`.
- Keycloak is built as an optimized local image before runtime so startup does
  not mutate the container filesystem.
- The Keycloak Postgres image is isolated from Chronicle Postgres, patched with
  Alpine security updates at build time, and removes the unused `gosu` binary.

Guardrails:

```bash
tests/security/run-all-security.sh sso /tmp/chronicle-sso-security-report
tests/security/sso-live-smoke-tests.sh http://10.23.4.137 chronicle-screentime-app.research.bcm.edu
```

Supply-chain note: `chronicle-keycloak-postgres:17.6-local` currently passes
Trivy high/critical scanning after the local patch layer. Keycloak is pinned to
the newest available upstream image and hardened at runtime, but current Trivy
data still reports upstream Keycloak/Quarkus/Netty/BouncyCastle high findings.
Do not claim Keycloak is SCA-clean until upstream publishes a fixed image and
the local image is rebuilt and rescanned.

## BCM Federation (OIDC preferred, SAML fallback)

BCM prefers OpenID Connect over SAML, so the realm import template provisions
**two** brokers for BCM and defaults the login flow to the OIDC one. Chronicle
itself is unaffected either way — it only ever validates Keycloak-issued OIDC
tokens. `KEYCLOAK_DEFAULT_IDP` (and the backend's `OIDC_IDP_HINT`) select which
broker the browser flow auto-redirects to.

### `bcm-oidc` — BCM Shibboleth OIDC OP (default)

Shibboleth IdP 4/5 can run the OIDC OP plugin. When BCM exposes it, this is the
cleaner path: the `amr` (MFA) claim flows through OIDC natively.

- Alias: `bcm-oidc`
- Display name: `BCM SSO`
- Provider: `oidc`, PKCE (S256), `client_secret_post`, signature validation on.
- Endpoints + credentials come from env (`BCM_OIDC_*` in `.env`); defaults follow
  the standard Shibboleth OIDC OP paths under `https://fedidp.bcm.edu/idp/profile/oidc/…`.
- Confirm the OP is live and capture the real endpoints with:

  ```bash
  docker/keycloak/probe-bcm-oidc.sh            # > /tmp/bcm-oidc.env to capture
  ```

  It fetches BCM's OIDC discovery doc, reports the `amr`/MFA signal, and prints a
  paste-ready `BCM_OIDC_*` block. A 404 means BCM has not exposed the OIDC OP yet
  (as of the last check the IdP is SAML-only) — stay on the SAML fallback below.
- Register Chronicle's Keycloak as an OIDC relying party with BCM. Redirect URI:

  ```text
  https://chronicle-screentime-app.research.bcm.edu/keycloak/realms/chronicle/broker/bcm-oidc/endpoint
  ```

Claim/attribute mapping (`syncMode: FORCE`, refreshed each login):

- `email` -> Keycloak `email`
- `given_name` -> Keycloak `firstName`
- `family_name` -> Keycloak `lastName`
- `preferred_username` -> Keycloak username
- `amr` -> Keycloak user attribute `amr`

**MFA passthrough:** the `amr` IdP mapper copies BCM's `amr` claim onto the user,
and a client protocol mapper re-emits `amr` (multivalued) into the Chronicle
access token. That is exactly the claim the backend `AmrClaimValidator` checks
when `CHRONICLE_SECURITY_REQUIRE_MFA=true` (accepted methods: `mfa`/`otp`/`hwk`,
RFC 8176). Before turning MFA enforcement on, verify three things — otherwise
every login 401s, or worse, silently passes:

1. **Vocabulary:** BCM's OP must emit `amr` containing one of `mfa`/`otp`/`hwk`.
   Shibboleth/Duo deployments often emit other tokens (e.g. `duo`, `sms`, `phr`)
   or a REFEDS `acr`. If BCM's MFA marker differs, add an IdP mapper that maps
   BCM's value onto one of the three accepted methods, or `AmrClaimValidator`
   rejects genuinely-MFA'd users.
2. **Freshness:** the `amr` mapper persists onto a Keycloak user attribute
   (`syncMode: FORCE`). This is correct only if BCM emits `amr` on *every* token
   per RFC 8176 (a fresh value overwrites each login). If BCM ever omits `amr` on
   a non-MFA login, a stale `amr=[mfa]` from a prior step-up would persist and
   false-pass. Confirm BCM always sets `amr` reflecting the current session.
3. **Broker:** this passthrough exists **only on `bcm-oidc`**. On the SAML
   fallback (`bcm`) there is no `amr` mapper, so `REQUIRE_MFA=true` + SAML = total
   lockout. Keep MFA enforcement off while on the SAML fallback, or add the SAML
   AuthnContext→`amr` mapper described below first.

### `bcm` — BCM SAML / Shibboleth (fallback)

Retained, verified, and ready — use it (set `KEYCLOAK_DEFAULT_IDP=bcm` and
`OIDC_IDP_HINT=bcm`) if BCM has not yet stood up the OIDC OP.

- Alias: `bcm`
- Display name: `BCM SSO (SAML fallback)`
- BCM IdP metadata source: `https://fedidp.bcm.edu/idp/shibboleth`
- Redirect SSO URL: `https://fedidp.bcm.edu/idp/profile/SAML2/Redirect/SSO`
- Redirect SLO URL: `https://fedidp.bcm.edu/idp/profile/SAML2/Redirect/SLO`
- Signature validation: enabled; assertions must be signed.
- Chronicle AuthnRequests are signed; SP metadata is signed.
- Attribute mapping: `mail`->`email`, `givenName`->`firstName`, `sn`->`lastName`,
  `eduPersonPrincipalName`->username.
- For MFA via SAML, map the assertion's AuthnContext/attribute into an `amr`
  user attribute (the OIDC path gets this for free).

Give BCM the Chronicle Keycloak SAML service-provider metadata:

```text
https://chronicle-screentime-app.research.bcm.edu/keycloak/realms/chronicle/broker/bcm/endpoint/descriptor
```

The ACS endpoint inside that descriptor is:

```text
https://chronicle-screentime-app.research.bcm.edu/keycloak/realms/chronicle/broker/bcm/endpoint
```

Default Chronicle realm role for brokered users (both brokers): `AuthenticatedUser`.
Keep `admin` assignment explicit in Keycloak. Do not map all BCM users to
Chronicle admin.

## Future Multi-University Broker

For broad university onboarding, do not add new SAML/OIDC logic to Chronicle.
Attach one federation broker to Keycloak instead:

- InCommon/eduGAIN: use the institutional federation SAML metadata aggregate.
- OpenAthens Keystone: use Keystone as the upstream identity broker.

Chronicle should continue validating only Keycloak-issued OIDC tokens.
