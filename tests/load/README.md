# Chronicle Load Testing

## Objective

Validate whether Chronicle can handle **1000 concurrent devices** uploading usage events and sensor data every 15 minutes.

At 1000 devices x 4 uploads/hour = **4000 requests/hour** sustained, with bursts when devices sync simultaneously.

## Test Scripts

| Script | Purpose |
|--------|---------|
| `chronicle-load-test.js` | Full k6 load test: enrollment, usage event uploads, sensor data uploads |
| `smoke-test.sh` | Lightweight curl-based smoke test for manual verification |

## Prerequisites

- **k6** installed (`command -v k6`)
- A running Chronicle instance (default: `http://127.0.0.1:40320`)
- A valid JWT token (generate with `docker/generate-jwt.sh`)
- A study ID (UUID) already created in the system

## Running the Load Test

### Quick smoke test (curl)

```bash
export BASE_URL=http://127.0.0.1:40320
export JWT_TOKEN=$(docker/generate-jwt.sh)
export STUDY_ID=<your-study-uuid>

bash tests/load/smoke-test.sh
```

### k6 load test

```bash
# Default: 100 VUs ramping to 1000
k6 run \
  --env JWT_TOKEN=<token> \
  --env STUDY_ID=<study-uuid> \
  tests/load/chronicle-load-test.js

# Custom VU count and base URL
k6 run \
  --env JWT_TOKEN=<token> \
  --env STUDY_ID=<study-uuid> \
  --env BASE_URL=http://chronicle.example.com \
  --env MAX_VUS=500 \
  tests/load/chronicle-load-test.js

# Output results to JSON for analysis
k6 run \
  --env JWT_TOKEN=<token> \
  --env STUDY_ID=<study-uuid> \
  --out json=results.json \
  tests/load/chronicle-load-test.js
```

## Test Plan

### Phase 1: Enrollment burst (1 min)
- Ramp 10 -> 100 VUs
- Each VU enrolls a unique participant and registers an Android device
- Validates enrollment API can handle onboarding spikes

### Phase 2: Steady upload (2 min)
- Ramp 100 -> 500 VUs
- Each VU uploads batches of 10 usage events (simulating 15-min device upload cycle)
- Validates the primary hot path: usage event ingestion

### Phase 3: Peak load (2 min)
- Ramp 500 -> 1000 VUs
- Mixed workload: 70% usage events, 30% sensor data uploads (batches of 500 samples)
- Validates system under target concurrency

### Phase 4: Cooldown (30s)
- Ramp 1000 -> 0 VUs
- Validates graceful handling of connection draining

## Thresholds

| Metric | Threshold | Rationale |
|--------|-----------|-----------|
| p95 latency (uploads) | < 500ms | Device timeout budget |
| p99 latency (uploads) | < 2000ms | Worst-case acceptable |
| p95 latency (enrollment) | < 1000ms | One-time operation, more tolerant |
| Error rate | < 1% | Data loss budget |
| Throughput | > 50 req/s at peak | 1000 devices / 15 min = ~1.1 req/s sustained, but burst factor ~50x |

## Key Endpoints Under Test

| Endpoint | Method | Hot/Cold | Payload |
|----------|--------|----------|---------|
| `/chronicle/v4/study/{id}/participant/{pid}/enroll` | POST | Warm (enrollment burst) | Device registration JSON |
| `/chronicle/v4/study/{id}/participant/{pid}/android` | POST | HOT (every 15 min) | Batch of 10 usage events |
| `/chronicle/v4/study/{id}/participant/{pid}/android/sensors` | POST | HOT (every 15 min) | Batch of 500 sensor samples |

## Interpreting Results

After a run, k6 outputs a summary including:

- `http_req_duration`: p50, p90, p95, p99 latencies
- `http_req_failed`: error rate
- `http_reqs`: total throughput
- Custom metrics: `upload_duration`, `enrollment_duration`, `sensor_upload_duration`

### Red flags to watch for

1. **p95 > 500ms on uploads**: Database or connection pool saturation
2. **Error rate > 1%**: Check server logs for OOM, connection exhaustion, or deadlocks
3. **Throughput plateau**: Server may be CPU-bound or hitting Hikari pool limits
4. **Increasing latency over time**: Memory leak or unbounded queue growth (check `upload_buffer` table size)

## Capacity Planning

| Devices | Uploads/hour | Sustained req/s | Peak req/s (burst) |
|---------|-------------|-----------------|---------------------|
| 100     | 400         | 0.11            | ~5                  |
| 500     | 2,000       | 0.56            | ~28                 |
| 1,000   | 4,000       | 1.11            | ~55                 |
| 5,000   | 20,000      | 5.56            | ~280                |

Peak req/s assumes all devices in a cohort sync within a 20-second window.
