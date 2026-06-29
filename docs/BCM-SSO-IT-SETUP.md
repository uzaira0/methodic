# Chronicle SSO — BCM IT Setup Packet

**Purpose:** what to hand BCM IT (and what to request back) to federate Chronicle
authentication with BCM's institutional identity provider, via **either OIDC or
SAML**. This is the forwardable deliverable; the IdP-agnostic auth contract lives
in [`INSTITUTIONAL-SSO-CONTRACT.md`](INSTITUTIONAL-SSO-CONTRACT.md), and the broker
config reference is [`../docker/keycloak/README.md`](../docker/keycloak/README.md).

Prepared: 2026-06-25.

---

## How it fits together (read first)

- **BCM** runs the identity provider (IdP) — `fedidp.bcm.edu`.
- **Chronicle** runs a **Keycloak broker** as the SAML SP / OIDC Relying Party.
  Keycloak is at `https://chronicle-screentime-app.research.bcm.edu/keycloak`,
  realm `chronicle`.
- The Chronicle application itself **never talks to BCM directly** — it only
  validates Keycloak-issued OIDC tokens. BCM only ever integrates with Keycloak.

So everything below is a **BCM-IdP ⇄ Chronicle-Keycloak** federation exchange.

### Current state (verified 2026-06-25)

A probe of `fedidp.bcm.edu` found the IdP **reachable and serving SAML metadata
(HTTP 200)** but **no OIDC discovery document at any standard path (HTTP 404)** —
i.e. **BCM is currently SAML-only**; the Shibboleth OIDC OP plugin is not exposed.

- **SAML** is what gets Chronicle live today.
- **OIDC** is the preferred path (cleaner, native `amr`/MFA passthrough) **once BCM
  enables their OIDC OP**.

Re-check at any time with: `docker/keycloak/probe-bcm-oidc.sh`.

Fixed facts for both paths:

| | |
|---|---|
| Keycloak base URL | `https://chronicle-screentime-app.research.bcm.edu/keycloak` |
| Realm | `chronicle` |
| BCM IdP host | `fedidp.bcm.edu` |

---

## Option A — SAML (works today)

Chronicle's Keycloak is the **SAML Service Provider (SP)**; BCM is the **IdP**.

### Provide to BCM IT

| Item | Value |
|---|---|
| **SP metadata** (signed, self-describing — the primary artifact) | Static file: [`sso/bcm-sp-metadata.xml`](sso/bcm-sp-metadata.xml) (attach to the ticket) — or live URL `https://chronicle-screentime-app.research.bcm.edu/keycloak/realms/chronicle/broker/bcm/endpoint/descriptor` |
| SP EntityID | `https://chronicle-screentime-app.research.bcm.edu/keycloak/realms/chronicle` |
| Assertion Consumer Service (ACS), HTTP-POST binding | `https://chronicle-screentime-app.research.bcm.edu/keycloak/realms/chronicle/broker/bcm/endpoint` |
| Single Logout (SLO) | `https://chronicle-screentime-app.research.bcm.edu/keycloak/realms/chronicle/broker/bcm/endpoint` |
| NameID format | `urn:oasis:names:tc:SAML:2.0:nameid-format:persistent` |
| Signing requirements | AuthnRequests **signed**; assertions **must be signed**; SP metadata **signed** (our signing certificate is embedded in the SP metadata above) |

> Shibboleth teams usually prefer a **static signed SP-metadata XML file** over a
> URL. The exported file is committed at [`sso/bcm-sp-metadata.xml`](sso/bcm-sp-metadata.xml)
> (entityID + ACS/SLO + SP signing cert, `AuthnRequestsSigned`/`WantAssertionsSigned`
> both true, document signed) — attach it directly to the IT ticket. Regenerate it
> with `curl -H 'Host: chronicle-screentime-app.research.bcm.edu' http://10.23.4.137/keycloak/realms/chronicle/broker/bcm/endpoint/descriptor`
> while the `sso` profile is running.

### Attributes to request BCM release

These four map to Keycloak `email` / `firstName` / `lastName` / username:

- `mail`
- `givenName`
- `sn`
- `eduPersonPrincipalName`

### Request from BCM IT

- Their IdP metadata: `https://fedidp.bcm.edu/idp/shibboleth`
  (already pinned in our realm, including their signing certificate — confirmation
  that this is current is sufficient).

---

## Option B — OIDC (preferred — once BCM enables their Shibboleth OIDC OP)

Chronicle's Keycloak is the **OIDC Relying Party (client)**; BCM is the **OpenID
Provider (OP)**.

### Provide to BCM IT

| Item | Value |
|---|---|
| Application / client name | Chronicle (Keycloak broker) |
| **Redirect URI / callback** | `https://chronicle-screentime-app.research.bcm.edu/keycloak/realms/chronicle/broker/bcm-oidc/endpoint` |
| Post-logout redirect (optional) | `https://chronicle-screentime-app.research.bcm.edu/keycloak` |
| Grant type | Authorization Code + **PKCE (S256)** |
| Token endpoint auth method | `client_secret_post` |
| Scopes | `openid profile email` |
| Claims we consume | `email`, `given_name`, `family_name`, `preferred_username` |

### Request from BCM IT (these go into our `docker/.env`)

1. **Client ID** → `BCM_OIDC_CLIENT_ID`
2. **Client Secret** → `BCM_OIDC_CLIENT_SECRET`
3. **Issuer / discovery URL** (`https://<issuer>/.well-known/openid-configuration`)
   — gives us the authorization / token / userinfo / JWKS endpoints. Our
   `docker/keycloak/probe-bcm-oidc.sh` reads this and emits a paste-ready
   `BCM_OIDC_*` block.

---

## MFA — required for HIPAA enforcement (do this on whichever path)

Chronicle can enforce MFA at the API boundary (`CHRONICLE_SECURITY_REQUIRE_MFA`),
which checks the RFC 8176 **`amr`** claim for an accepted method (`mfa`, `otp`,
or `hwk`). For that to work, BCM must signal the MFA event:

- **OIDC:** release the **`amr`** claim (RFC 8176) on MFA logins — and/or an `acr`
  carrying the REFEDS MFA value.
- **SAML:** assert the **REFEDS MFA** AuthnContextClassRef
  `https://refeds.org/profile/mfa` (the higher-ed/research-federation standard);
  we map it to `amr`.

> **Do not enable MFA enforcement until BCM confirms this is actually released** —
> otherwise every login is rejected (401). Confirm with a test step-up login first.

---

## Next steps on our side (after BCM responds)

**SAML:**
1. Signed SP metadata already exported → [`sso/bcm-sp-metadata.xml`](sso/bcm-sp-metadata.xml). Attach it to the IT ticket.
2. On receiving BCM's confirmation, verify the pinned IdP cert/metadata is current.
3. Keep `KEYCLOAK_DEFAULT_IDP=bcm` and `OIDC_IDP_HINT=bcm` (already set on this box).

**OIDC:**
1. Run `docker/keycloak/probe-bcm-oidc.sh` (now returns 200), capture the
   `BCM_OIDC_*` endpoints.
2. Paste those + the BCM-issued `BCM_OIDC_CLIENT_ID` / `BCM_OIDC_CLIENT_SECRET`
   into `docker/.env`.
3. Flip `KEYCLOAK_DEFAULT_IDP=bcm-oidc` and `OIDC_IDP_HINT=bcm-oidc`.
4. Confirm `amr` is emitted on a step-up login **before** turning on MFA
   enforcement.

The realm already imports **both** brokers (`bcm-oidc` preferred, `bcm` SAML
fallback), so switching paths is an env-flip, not a rebuild.

---

## Quick reference — who provides what

| Direction | SAML | OIDC |
|---|---|---|
| **Chronicle → BCM** | SP metadata (EntityID, ACS/SLO, signing cert) | Redirect URI, grant/PKCE, scopes, claims |
| **BCM → Chronicle** | IdP metadata; release mail/givenName/sn/eppn; REFEDS MFA AuthnContext | Client ID + Secret; issuer/discovery URL; emit `amr`/`acr` |
