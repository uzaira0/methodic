## Chronicle Server Auth And Legacy Config Inventory

Updated: 2026-03-12

### Purpose

This inventory maps the remaining provider-specific and legacy-named auth wiring
now that the active Chronicle server runtime has already been cut over away from
`Auth0Pod` and `/chronicle/config.json`.

### Active Runtime State

- `chronicle-server` no longer imports or registers `Auth0Pod` in its active
  bootstrap path.
- The active auth/session contract is owned by
  `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/AuthTokenController.kt`
  via `/chronicle/v3/auth/session`, `/testing-login`, `/set-cookie`, and `/logout`.
- The modern and legacy web shells now rely on that server session bridge rather
  than a runtime `/chronicle/config.json` fetch.

### Remaining Config And Naming Debt

#### Config-backed local user services

- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/users/ConfiguredUserListingService.kt`
  - Still provides testing-login JWT minting for non-SSO environments
  - Should become either an explicit local-test-only shim or an institutional SSO adapter
- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/directory/ConfiguredUserDirectoryService.kt`
  - Still builds the local user directory from deployment config
  - Needs to align with the eventual institutional identity source
- `chronicle-api/src/main/kotlin/com/openlattice/chronicle/users/UserSearchFields.kt`
  - The DTO is now provider-neutral, but Android and any remaining clients need
    to keep pace with the renamed contract

### Security and Configuration Coupling

- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/OpenRedirectFilter.kt`
  - Previously defaulted redirect allowlists to `chronicle-screentime-app.research.bcm.edu`
- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/SsrfConfig.kt`
  - Previously defaulted outbound allowlists to Auth0 hosts
- `chronicle-server/src/main/resources/ssrf.yaml`
  - Previously shipped with Auth0 hosts as the checked-in default
- `docker/chronicle-auth.yaml`, `docker/chronicle-auth.yaml.template`, and related backup/restore scripts
  - Legacy Auth0 artifact names were migrated to Chronicle-owned auth config names in Docker-backed deployments and scripts.
- `docs/SECURITY-HARDENING.md`
  - Still contains some legacy examples and CSP references that should be rewritten

### Transitional Web Coupling To Remove Later

- `chronicle-web/src/core/auth/storage/authStorageKeys.js`
  - Only legacy browser-storage cleanup values remain for migration of old browser state; the exported symbols are now provider-neutral
- `chronicle-web/src/core/auth/utils/getUserInfo.js`
  - Migrates legacy user info from old browser storage into the Chronicle storage key on read
- `chronicle-web/src/core/auth/utils/storeAuthInfo.js`
  - Writes the Chronicle user info storage key while leaving JWT persistence disabled
- `chronicle-web/src/core/auth/bootstrap/bootstrapLegacyAuthSession.js`
  - Replays the temporary server testing-login/session path for route guards and Axios refresh until SSO replaces it

### Ordered Removal Plan

1. Replace `ConfiguredUserListingService` and `ConfiguredUserDirectoryService`
   with explicit institutional SSO integrations or test-only local shims.
2. Completed: rename deployment artifacts (`chronicle-auth.yaml`,
   `chronicle-auth.yaml.template`) to Chronicle-owned names.
3. Remove the remaining legacy browser-storage cleanup values and server/runtime
   symbols that still encode the old identity model.
4. Remove the testing-login bridge once institutional SSO is live.

### Blockers

- JVM validation is now runnable in this workspace when Java 21 is configured via
  `JAVA_HOME`.
- Deployment compose and backup/restore flows now reference Chronicle-owned auth
  filenames, but the migration is still incomplete across all deployment
  variants and operator documentation.
