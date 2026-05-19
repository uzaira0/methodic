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

## BCM SAML

The realm import template already provisions BCM as a SAML identity provider:

- Alias: `bcm`
- Display name: `BCM SSO`
- BCM IdP metadata source: `https://fedidp.bcm.edu/idp/shibboleth`
- Redirect SSO URL: `https://fedidp.bcm.edu/idp/profile/SAML2/Redirect/SSO`
- Redirect SLO URL: `https://fedidp.bcm.edu/idp/profile/SAML2/Redirect/SLO`
- Signature validation: enabled; assertions must be signed.
- Chronicle AuthnRequests are signed.
- Chronicle SP metadata is signed and includes the SP signing key.
- Default Chronicle realm role for brokered users: `AuthenticatedUser`.

The broker imports common Shibboleth attributes:

- `mail` -> Keycloak `email`
- `givenName` -> Keycloak `firstName`
- `sn` -> Keycloak `lastName`
- `eduPersonPrincipalName` -> Keycloak username

Give BCM the Chronicle Keycloak SAML service-provider metadata:

```text
https://chronicle-screentime-app.research.bcm.edu/keycloak/realms/chronicle/broker/bcm/endpoint/descriptor
```

The ACS endpoint inside that descriptor is:

```text
https://chronicle-screentime-app.research.bcm.edu/keycloak/realms/chronicle/broker/bcm/endpoint
```

Keep `admin` assignment explicit in Keycloak. Do not map all BCM users to
Chronicle admin.

## Future Multi-University Broker

For broad university onboarding, do not add new SAML/OIDC logic to Chronicle.
Attach one federation broker to Keycloak instead:

- InCommon/eduGAIN: use the institutional federation SAML metadata aggregate.
- OpenAthens Keystone: use Keystone as the upstream identity broker.

Chronicle should continue validating only Keycloak-issued OIDC tokens.
