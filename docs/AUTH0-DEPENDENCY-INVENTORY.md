## Chronicle Server Auth0 Dependency Inventory

Updated: 2026-03-11

### Purpose

This inventory maps the remaining Auth0-specific wiring in `chronicle-server` so institutional SSO replacement can be executed in ordered slices instead of broad search-and-replace work.

### Runtime Wiring

#### Server bootstrap pods

- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/ChronicleServer.kt`
  - Imports `com.geekbeast.auth0.Auth0Pod`
  - Registers `Auth0Pod::class.java` in `rhizomePods`
- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/pods/ChronicleServerServicesPod.kt`
  - Imports `Auth0Pod` and `Auth0Configuration`
  - Uses `@Import(Auth0Pod::class, ...)`
  - Injects `Auth0Configuration`
  - Constructs `LocalUserListingService(auth0Configuration)`
  - Constructs `LocalUserDirectoryService(auth0Configuration)`
- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/mapstores/MapstoresPod.kt`
  - Imports `Auth0Pod`
  - Uses `@Import(PostgresPod::class, Auth0Pod::class)`

#### Auth0-backed local user services

- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/users/LocalUserListingService.kt`
  - Depends directly on `Auth0Configuration`
  - Generates local JWTs from configured Auth0 clients and users
  - Logs generated JWTs at startup
- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/directory/LocalUserDirectoryService.kt`
  - Depends directly on `Auth0Configuration`
  - Builds an in-memory `User` map from configured Auth0 users
- `chronicle-api/src/main/kotlin/com/openlattice/chronicle/users/Auth0UserSearchFields.kt`
  - Auth0-specific naming survives in the public API model used by user search

### Security and Configuration Coupling

- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/OpenRedirectFilter.kt`
  - Previously defaulted redirect allowlists to `methodic.us.auth0.com`
- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/SsrfConfig.kt`
  - Previously defaulted outbound allowlists to Auth0 hosts
- `chronicle-server/src/main/resources/ssrf.yaml`
  - Previously shipped with Auth0 hosts as the checked-in default
- `docs/SECURITY-HARDENING.md`
  - Still contains Auth0-specific examples and CSP references that need a later pass

### Transitional Web Coupling To Remove Later

- `chronicle-web/src/core/auth/storage/authStorageKeys.js`
  - Legacy Auth0 storage key names still exist only for cleanup and migration of old browser state
- `chronicle-web/src/core/auth/utils/getUserInfo.js`
  - Migrates legacy user info from old browser storage into the Chronicle storage key on read
- `chronicle-web/src/core/auth/utils/storeAuthInfo.js`
  - Writes the Chronicle user info storage key while leaving JWT persistence disabled
- `chronicle-web/src/core/auth/bootstrap/fetchBootstrapToken.js`
  - Maintains `/chronicle/config.json` bootstrap for non-SSO testing
- `chronicle-web/src/core/auth/bootstrap/bootstrapLegacyAuthSession.js`
  - Replays the temporary bootstrap-token path for route guards and Axios refresh until SSO replaces it

### Ordered Removal Plan

1. Remove Auth0-specific runtime defaults from redirect and SSRF configuration.
2. Introduce provider-neutral auth/session interfaces for server bootstrap and local user lookup.
3. Replace `LocalUserListingService` and `LocalUserDirectoryService` with SSO-neutral implementations or explicit test-only shims.
4. Stop importing `Auth0Pod` from Chronicle server pods once replacement services exist.
5. Remove the remaining legacy Auth0 storage key names and API/web symbols that still encode Auth0 as the identity model.
6. Remove the `/chronicle/config.json` bootstrap path once institutional SSO is live.

### Blockers

- Local JVM validation is currently blocked in this workspace because `java` and `JAVA_HOME` are not configured.
- The broader `rhizome` authentication stack still provides `Auth0Pod` and `Auth0Configuration`, so server removal needs to coordinate with those shared libraries instead of patching Chronicle in isolation.
