# Chronicle load testing

Run the pilot ingest workload against an isolated clean stack with synthetic study data.
Each virtual user represents one enrolled device and starts an upload every 60 seconds.
At 1,000 devices this produces 60,000 usage requests/hour, plus sensor requests on 30% of
iterations. Ramp cohorts through 100, 500 and `MAX_VUS` devices, then drain connections.

## Prepare synthetic fixtures

Create a study with active dates and versioned collection settings enabling usage events
and the tested Android sensors. Create synthetic participants, complete normal invitation
and per-module consent enrollment, and acknowledge the current collection settings. Keep
one distinct enrolled device credential per virtual user in a private mode-0600 JSON file:

```json
[
  {"participant_id":"synthetic-1", "device_id":"<source device ID used at enrollment>", "api_key":"<enrollment-issued device key>"}
]
```

Set `DEVICE_FIXTURES_FILE` to its absolute path. The test sends `X-Api-Key` and
`X-Chronicle-Device-Id`; it validates fixture shape before starting and never prints keys.
Use study-approved synthetic credentials; never export real participant keys into fixtures.
The payload uses the current usage-event class discriminator and sensor enum values.
Enrollment happens before measurement so invitation failures cannot masquerade as capacity.

## Run and retain evidence

Install k6 and Docker, start the exact release images on a newly created database, and set
these variables in the runner environment:

```bash
export BASE_URL=https://synthetic-pilot.example.test
export STUDY_ID=<synthetic-study-uuid>
export DEVICE_FIXTURES_FILE=/private/synthetic-devices.json
export COMPOSE_PROJECT_NAME=<isolated-project-name>
export MAX_VUS=1000
export CHRONICLE_LOAD_REPORT_DIR=/private/pilot-run-001
scripts/chronicle-pilot-load.sh
```

Use a fresh report directory for each run. The runner retains k6 samples, the full summary
and redacted web edge logs. `UPLOAD_INTERVAL_SECONDS` changes the default 60-second
start-to-start interval. Tagged response counters distinguish acceptance, throttling,
authentication, server, transport and rejected requests. Any authentication or payload
rejection invalidates the fixture and must be resolved before reporting capacity.

The current budgets are p95 upload latency below 500 ms, p99 below 2,000 ms, and an error
rate below 1%. They are provisional budgets; the committed baseline is unmeasured.
Review `http_req_duration`, `http_req_failed`, `http_reqs`, `upload_duration` and
`sensor_upload_duration` alongside accepted event/sample counts and edge response classes.

Repeat each clean-stack run twice while increasing `MAX_VUS`. Record image/source digests,
host CPU/RAM/storage, encryption/monitoring configuration, participant/event/sample counts,
throughput, p95/p99 latency, errors and the first VU level that exceeds the thresholds.
Replace `tests/perf/k6-baselines.json` with the measured summary and a `measurement` object
containing `verified: true`, `runs`, `source_revision`, `environment`, `fixtures` and
`first_saturation_vus`. The release regression gate rejects the unmeasured budget.
An explicitly local budget check can set `K6_ALLOW_UNMEASURED_BUDGET=true`.
