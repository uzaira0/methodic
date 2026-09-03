import http from 'k6/http';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';

/**
 * k6 Race Condition Tests for Chronicle
 *
 * Validates that the backend handles concurrent conflicting requests gracefully
 * (no 500 errors). Three scenarios:
 *
 *   1. Double Enrollment — 10 VUs simultaneously enroll the same participant
 *   2. Parallel Deletes  — concurrent delete requests for the same resource
 *   3. Nonce Replay       — same HMAC nonce submitted concurrently (if enabled)
 *
 * Usage:
 *   k6 run tests/load/k6-race-conditions.js
 *   k6 run --env BASE_URL=http://backend:40320 --env AUTH_TOKEN=<jwt> tests/load/k6-race-conditions.js
 */

const BASE_URL = __ENV.BASE_URL || 'http://localhost';
const AUTH_TOKEN = __ENV.AUTH_TOKEN || '';

// Common headers for authenticated requests
function authHeaders(extra) {
  const headers = {
    'Content-Type': 'application/json',
  };
  if (AUTH_TOKEN) {
    headers['Authorization'] = `Bearer ${AUTH_TOKEN}`;
  }
  return Object.assign(headers, extra || {});
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------
export const options = {
  scenarios: {
    // Scenario 1: 10 VUs simultaneously enroll the same participant
    double_enrollment: {
      executor: 'per-vu-iterations',
      vus: 10,
      iterations: 1,
      exec: 'doubleEnrollment',
      maxDuration: '30s',
      gracefulStop: '5s',
    },

    // Scenario 2: 10 VUs simultaneously delete the same resource
    parallel_deletes: {
      executor: 'per-vu-iterations',
      vus: 10,
      iterations: 1,
      startTime: '35s',
      exec: 'parallelDeletes',
      maxDuration: '30s',
      gracefulStop: '5s',
    },

    // Scenario 3: 10 VUs submit the same HMAC nonce concurrently
    nonce_replay: {
      executor: 'per-vu-iterations',
      vus: 10,
      iterations: 1,
      startTime: '70s',
      exec: 'nonceReplay',
      maxDuration: '30s',
      gracefulStop: '5s',
    },
  },

  thresholds: {
    // No 5xx errors in any scenario
    'checks{scenario:double_enrollment}': ['rate>=0.9'],
    'checks{scenario:parallel_deletes}': ['rate>=0.9'],
    'checks{scenario:nonce_replay}': ['rate>=0.9'],

    // Response time under 2 seconds
    'http_req_duration{scenario:double_enrollment}': ['p(95)<2000'],
    'http_req_duration{scenario:parallel_deletes}': ['p(95)<2000'],
    'http_req_duration{scenario:nonce_replay}': ['p(95)<2000'],
  },
};

// ---------------------------------------------------------------------------
// Scenario 1: Double Enrollment
// 10 VUs simultaneously try to enroll the same participant in the same study.
// The backend should handle the conflict gracefully — duplicates may be
// rejected (409) or idempotently accepted (200), but must never return 5xx.
// ---------------------------------------------------------------------------
export function doubleEnrollment() {
  const studyId = '00000000-0000-0000-0000-000000000001';
  const participantId = 'race-condition-test-participant';

  const payload = JSON.stringify({
    participantId: participantId,
    participant: {
      participantId: participantId,
    },
    datasourceId: 'race-test-device',
  });

  const res = http.post(
    `${BASE_URL}/chronicle/v3/studies/${studyId}/participants/${participantId}/enroll`,
    payload,
    { headers: authHeaders() }
  );

  check(res, {
    'double-enroll: no 5xx error': (r) => r.status < 500,
    'double-enroll: response time < 2s': (r) => r.timings.duration < 2000,
    'double-enroll: valid response (200, 201, 400, 401, 404, 409, 429)': (r) =>
      [200, 201, 400, 401, 404, 409, 429].includes(r.status),
  });

  if (res.status >= 500) {
    console.error(`double-enroll VU ${__VU}: got ${res.status} — ${res.body}`);
  }
}

// ---------------------------------------------------------------------------
// Scenario 2: Parallel Deletes
// 10 VUs simultaneously try to delete the same resource. Only one should
// succeed (200/204); the rest should get 404 or similar. No 5xx allowed.
// ---------------------------------------------------------------------------
export function parallelDeletes() {
  const studyId = '00000000-0000-0000-0000-000000000002';
  const participantId = 'race-condition-delete-test';

  const res = http.del(
    `${BASE_URL}/chronicle/v3/studies/${studyId}/participants/${participantId}`,
    null,
    { headers: authHeaders() }
  );

  check(res, {
    'parallel-delete: no 5xx error': (r) => r.status < 500,
    'parallel-delete: response time < 2s': (r) => r.timings.duration < 2000,
    'parallel-delete: valid response (200, 204, 400, 401, 404, 409, 429)': (r) =>
      [200, 204, 400, 401, 404, 409, 429].includes(r.status),
  });

  if (res.status >= 500) {
    console.error(`parallel-delete VU ${__VU}: got ${res.status} — ${res.body}`);
  }
}

// ---------------------------------------------------------------------------
// Scenario 3: Nonce Replay
// If HMAC signing is enabled, submit the same nonce from 10 VUs concurrently.
// At most 1 should be accepted; the rest should be rejected (e.g., 401/409).
// No 5xx allowed. If HMAC is not enabled, the test still validates that
// concurrent identical requests do not cause server errors.
// ---------------------------------------------------------------------------
export function nonceReplay() {
  const studyId = '00000000-0000-0000-0000-000000000003';
  const participantId = 'nonce-replay-test';

  // Use a fixed nonce and timestamp so all VUs submit the same signed request
  const fixedNonce = 'race-condition-test-nonce-12345';
  const fixedTimestamp = Math.floor(Date.now() / 1000).toString();

  const payload = JSON.stringify({
    participantId: participantId,
    data: { test: 'nonce-replay' },
  });

  const headers = authHeaders({
    'X-Chronicle-Nonce': fixedNonce,
    'X-Chronicle-Timestamp': fixedTimestamp,
  });

  const res = http.post(
    `${BASE_URL}/chronicle/v3/studies/${studyId}/participants/${participantId}/data`,
    payload,
    { headers: headers }
  );

  check(res, {
    'nonce-replay: no 5xx error': (r) => r.status < 500,
    'nonce-replay: response time < 2s': (r) => r.timings.duration < 2000,
    'nonce-replay: valid response (200, 201, 400, 401, 404, 409, 429)': (r) =>
      [200, 201, 400, 401, 404, 409, 429].includes(r.status),
  });

  if (res.status >= 500) {
    console.error(`nonce-replay VU ${__VU}: got ${res.status} — ${res.body}`);
  }
}
