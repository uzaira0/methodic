# SSO Touchpoints

## Contract and audit docs

- `docs/INSTITUTIONAL-SSO-CONTRACT.md`
- `docs/AUTH0-DEPENDENCY-INVENTORY.md`
- `docs/SECURITY-HARDENING.md`

## Server

- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/ChronicleServer.kt`
- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/pods/ChronicleServerServicesPod.kt`
- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/mapstores/MapstoresPod.kt`
- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/AuthTokenController.kt`
- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/OpenRedirectFilter.kt`
- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/SsrfConfig.kt`
- `chronicle-server/src/main/resources/ssrf.yaml`

## Web

- `chronicle-web/src/index.js`
- `chronicle-web/src/core/auth/bootstrap/*`
- `chronicle-web/src/core/auth/utils/*`
- `chronicle-web/src/core/api/axios/*`
- `chronicle-web/src/common/constants/strings.js`

## Automation

- `scripts/check-sso-drift.sh`
- `scripts/chronicle-preflight.sh`
- `scripts/chronicle-smoke.sh`
