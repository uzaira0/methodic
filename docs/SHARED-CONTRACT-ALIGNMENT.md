## Shared Contract Alignment

Updated: 2026-03-12

### Scope

This note records the current contract alignment between `chronicle-web`,
`chronicle-server`, `chronicle-api`, and the Android app after the recent auth
and route modernization work.

### Current Findings

#### Web and server

- `chronicle-web` now relies on `/chronicle/v3/auth/session`,
  `/chronicle/v3/auth/testing-login`, `/chronicle/v3/auth/set-cookie`, and
  `/chronicle/v3/auth/logout`.
- `chronicle-server` owns those contracts directly in
  `AuthTokenController.kt`.
- The web runtime no longer depends on `/chronicle/config.json` as an active
  bootstrap mechanism.

#### `chronicle-api`

- `UserSearchFields` is provider-neutral and now models `email` and `name`
  instead of Auth0-shaped field names.
- `PrincipalApi` still returns `com.auth0.json.mgmt.users.User` for user listing
  and search endpoints.
- `chronicle-api/build.gradle` still depends on the Auth0 Java SDK because of
  those DTOs.
- `chronicle-api/chronicle.yaml` still exposes the user-search schema, but it
  does not currently model the new web/server auth session endpoints because the
  web client uses direct fetches instead of the Retrofit interface.

#### Android

- No direct Android references were found for:
  - `/chronicle/v3/auth/session`
  - `/chronicle/v3/auth/testing-login`
  - `/chronicle/config.json`
  - `chronicle_auth`
  - `ol_csrf_token`
- That means the recent web/server auth changes do not currently break Android,
  but Android is also not yet aligned to consume the new auth/session contract
  if that becomes necessary.

### Recommended Next Shared-Contract Changes

1. Replace Auth0 `User` DTO usage in `chronicle-api` with a Chronicle-owned
   provider-neutral user summary type.
2. Decide whether the auth/session endpoints belong in `chronicle-api`; if they
   do, add explicit DTOs and Retrofit contracts instead of leaving the web as a
   direct-fetch special case.
3. If Android will ever participate in the same browser-to-server auth/session
   contract, add dedicated mobile-facing auth/session interfaces rather than
   reusing the web bootstrap semantics implicitly.

### Status

- Web/server contract drift: reduced
- API/shared DTO drift: still present
- Android auth impact: reviewed, no direct breakage found
