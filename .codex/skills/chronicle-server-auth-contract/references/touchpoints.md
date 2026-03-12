# Chronicle Server Auth Contract Touchpoints

## Main files

- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/AuthTokenController.kt`
- `chronicle-server/src/test/kotlin/com/openlattice/chronicle/controllers/AuthTokenControllerTest.kt`
- `scripts/chronicle-server-auth-smoke.sh`
- `scripts/chronicle-smoke.sh`
- `.github/workflows/ci.yml`

## Validation

- Local syntax checks:
  - `bash -n scripts/chronicle-server-auth-smoke.sh`
  - `bash -n scripts/chronicle-smoke.sh`
- JVM contract lane:
  - `./scripts/chronicle-server-auth-smoke.sh`
- Full repo smoke when Java is available:
  - `./scripts/chronicle-smoke.sh`

## Current environment note

- In this workspace, `java` and `JAVA_HOME` are still missing, so only shell and CI-config validation can run locally.
