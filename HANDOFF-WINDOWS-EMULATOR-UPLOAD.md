# Chronicle Windows Emulator Upload Handoff

Date: 2026-05-19

## Purpose

Use a Windows Android emulator to validate the BCM Chronicle Android app
against the local BCM backend after the mobile HMAC and Upload Now fixes.

## What Changed

The Android app now signs mobile API requests that hit:

- `/chronicle/v3/study/*`
- `/chronicle/v4/study/*`

The backend requires these headers:

- `X-Chronicle-Signature`
- `X-Chronicle-Timestamp`
- `X-Chronicle-Nonce`

The app computes the same canonical string as the backend:

```text
METHOD|PATH|TIMESTAMP|NONCE|SHA256(BODY)
```

The Upload Now button now queues the combined upload worker, so one tap runs
both usage upload and sensor upload logic. The UI upload progress observer now
tracks the combined periodic worker and the immediate combined worker.

## Verified On Linux Host

The local Linux emulator could not complete boot. Both API 35 AVD attempts
exited before `sys.boot_completed=1`, so full UI validation is still pending on
Windows.

Verified without emulator:

- Android debug APK builds with the backend signing secret injected.
- Android unit tests pass.
- HMAC unit test passes with a fixed server-compatible signature vector.
- Backend HMAC smoke passes:
  - unsigned mobile request is rejected with `401`
  - signed mobile request reaches application code
  - replayed nonce is rejected with `401`

## Build APK

From the repo root on the Linux backend/build host:

```bash
cd /home/opt/chronicle/chronicle
export MOBILE_SIGNING_SECRET="$(docker inspect chronicle-backend --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^MOBILE_SIGNING_SECRET=//p')"
./gradlew :app:assembleDebug --console=plain -Dorg.gradle.java.home=/home/uzair/.local/jdks/temurin-21
```

APK path:

```text
/home/opt/chronicle/chronicle/app/build/outputs/apk/debug/app-debug.apk
```

Do not paste or commit `MOBILE_SIGNING_SECRET`.

## Install On Windows Emulator

On Windows, use the Android SDK platform-tools `adb.exe`.

If the APK is copied to Windows:

```powershell
adb devices -l
adb install -r .\app-debug.apk
```

If installing from WSL to a Windows emulator, connect to the Windows ADB server
or copy the APK to Windows first. The simplest path is copying the APK to
Windows and using Windows `adb.exe`.

## Backend URL

Use the production/local BCM URL in the app:

```text
https://chronicle-screentime-app.research.bcm.edu
```

If the emulator cannot resolve the BCM hostname, validate DNS/VPN first from
the Windows host. If needed, temporarily test with the local Traefik host only
after confirming the app accepts the URL and the backend host routing still
matches BCM deployment expectations.

## Manual Test Flow

1. Start the Windows Android emulator.
2. Install the signed debug APK.
3. Open Chronicle.
4. Enter a real BCM study UUID.
5. Enter a test participant ID approved for this study.
6. Tap Enroll.
7. Confirm enrollment succeeds and the app reaches the main screen.
8. Grant Usage Access when prompted.
9. Leave the app open long enough to collect usage data, or generate app usage
   by opening several apps and returning to Chronicle.
10. Tap Upload Now.
11. Confirm the upload progress indicator appears briefly.
12. Confirm Last Upload changes from `Never` to a current timestamp.
13. Confirm Latest Timestamp Uploaded advances when usage rows exist.
14. Confirm Items remaining to upload returns to `0` after successful upload.

## Backend Checks During Test

On the backend host:

```bash
docker logs chronicle-backend --since 10m | rg -i 'signature|enroll|upload|android|error|warn|exception'
```

Expected:

- No `Missing signature headers` for emulator app requests.
- Enrollment should not fail with `401`.
- Upload requests should reach application code.
- If upload returns an error, check whether it is API key, study/participant,
  source device, or payload validation related.

Container status:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | rg 'chronicle-(backend|traefik|postgres|keycloak)'
```

Expected:

- `chronicle-backend` healthy
- `chronicle-traefik` running
- `chronicle-postgres` healthy
- `chronicle-postgres-replica` healthy
- `chronicle-keycloak` healthy

## Known Caveat

The current implementation injects the shared mobile HMAC secret into the APK at
build time. This is acceptable only as a local BCM dogfooding unblocker. For a
stronger production model, replace the global APK secret with per-device signing
material issued during enrollment.

## Files Most Relevant To This Test

- `chronicle/app/src/main/java/com/openlattice/chronicle/security/MobileApiSigningInterceptor.kt`
- `chronicle/app/src/main/java/com/openlattice/chronicle/utils/Utils.kt`
- `chronicle/app/src/main/java/com/openlattice/chronicle/services/upload/UploadWorker.kt`
- `chronicle/app/src/main/java/com/openlattice/chronicle/services/upload/CombinedUploadWorker.kt`
- `chronicle/app/src/main/java/com/openlattice/chronicle/models/UploadStatusModel.kt`
- `chronicle/app/src/test/java/com/openlattice/chronicle/security/MobileApiSigningInterceptorTest.kt`

