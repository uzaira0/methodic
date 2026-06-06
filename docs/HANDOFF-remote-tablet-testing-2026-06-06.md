# Remote Android Tablet Testing

Date: 2026-06-06

## Goal

Enroll and test a physical Android tablet that is on a home network while the
Chronicle server is on a different network. The home computer runs `adb`; the
tablet talks to Chronicle over the network.

## Required Topology

The tablet must reach Chronicle through a public or VPN-routable HTTPS URL:

```text
tablet -> HTTPS Chronicle URL -> Traefik/mobile router -> chronicle-backend
home computer -> USB/Wi-Fi adb -> tablet
```

Do not use raw HTTP. The Android enrollment flow rejects non-HTTPS `serverUrl`
values, and this is the correct HIPAA posture.

Acceptable remote access options:

- The existing production/local BCM public URL with a valid trusted certificate.
- A VPN path that exposes that same HTTPS URL to the tablet.
- A temporary tunnel only if it is approved for the data being tested and
  terminates with a trusted HTTPS certificate.

Avoid unapproved commodity public tunnels for participant data. If a tunnel is
used for dogfooding, use synthetic participant IDs and no real PHI unless the
deployment/compliance owner has explicitly approved it.

## Server Checklist

- `DOMAIN` must resolve from the tablet's home network to the Chronicle HTTPS
  edge.
- The certificate must be trusted by Android without installing a custom test
  root on the tablet.
- The mobile API must be reachable at the same base URL the app receives in
  `serverUrl`; do not add an `/api/mobile` prefix for the Traefik deployment.
- The existing Traefik mobile router already forwards `/chronicle/v4/`,
  `/chronicle/v3/`, `/chronicle/v2/`, `/chronicle/study/`, and
  `/chronicle/limits/` to `chronicle-backend`.
- v4 enrollment is public only as a bootstrap step. After enrollment, the server
  issues a per-device API key and subsequent v4 writes require that key.
- Register the participant in Chronicle web before starting the Android
  enrollment deep link.

## Repo Support

Use:

```bash
scripts/android-remote-tablet-enrollment.sh \
  --server-url https://chronicle-screentime-app.research.bcm.edu \
  --study-id <study-uuid> \
  --participant-id <participant-id> \
  --emit-env /tmp/chronicle-remote-tablet.env
```

The script:

- refuses non-HTTPS server URLs;
- checks `/chronicle/v3/healthz` for HTTPS reachability; `200` is healthy, and
  `401`/`403` still confirms the edge is reachable when that endpoint is auth
  protected;
- prints a `chronicle://enroll?...&serverUrl=https%3A...` deep link;
- prints exact `adb` commands for the home computer;
- can run the commands directly with `--run-adb` when executed on the home
  computer.

Before running the enrollment deep link, register the participant ID in the
Chronicle web UI for the target study.

## Home Computer Commands

After building or copying the debug APK to the home computer:

```bash
adb devices -l
adb install -r chronicle/app/build/outputs/apk/debug/app-debug.apk
adb shell appops set com.openlattice.chronicle.bcmtest.debug GET_USAGE_STATS allow
```

Then run the `adb shell am start ... chronicle://enroll?...` command printed by
`scripts/android-remote-tablet-enrollment.sh`.

For faster debug upload cadence on a debug build:

```bash
adb shell am broadcast \
  -n com.openlattice.chronicle.bcmtest.debug/com.openlattice.chronicle.debug.DebugSyncConfigReceiver \
  -a com.openlattice.chronicle.debug.SET_SYNC_CONFIG \
  --es strategy coordinated_collect_then_upload \
  --el interval_minutes 15 \
  --ez run_now true \
  --ez reschedule true
```

## Verification

On the server:

```bash
curl -fsS https://<chronicle-host>/chronicle/v3/healthz
docker logs chronicle-backend --since 10m | rg -i 'enroll|android|signature|upload|error|exception'
```

Optional HMAC edge check:

```bash
BASE_URL=https://<chronicle-host> \
TEST_STUDY_ID=<study-uuid> \
TEST_PARTICIPANT_ID=<participant-id> \
tests/security/test-hmac-enforcement.sh
```

After enrollment, the participant page should show one app-device instance for
the tablet. Re-enrolling the same installed app should add an enrollment event,
not a second device instance. Clearing app data or reinstalling in a way that
destroys app data will create a new app-device instance.

## Notes

- Survey and Questionnaire remain backend web forms. Android notifications only
  deep-link to those web forms.
- Time Use Diary is web-only and has no Android reminder path.
- The app-device instance ID is generated and persisted by the Android app; do
  not manually type a device ID for normal enrollment testing.
