// =============================================================================
// k6 Race Condition / TOCTOU Load Tests for Chronicle Backend
// =============================================================================
// Tests concurrent access patterns that could trigger race conditions in the
// Chronicle backend, including double enrollment, nonce replay, parallel
// deletes, and settings update races.
//
// Prerequisites:
//   - k6 installed (https://k6.io)
//   - Chronicle backend running
//
// Usage:
//   k6 run -e STUDY_ID=<uuid> -e AUTH_TOKEN=<jwt> k6-race-conditions.js
//   k6 run -e BASE_URL=http://host:40320 -e STUDY_ID=<uuid> -e AUTH_TOKEN=<jwt> k6-race-conditions.js
//
// Filter by scenario:
//   k6 run --tag scenario=double_enrollment k6-race-conditions.js
// =============================================================================

import http from 'k6/http';
import { check, group } from 'k6';
import { Counter, Rate } from 'k6/metrics';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const BASE_URL = __ENV.BASE_URL || 'http://localhost:40320';
const STUDY_ID = __ENV.STUDY_ID || '00000000-0000-0000-0000-000000000000';
const AUTH_TOKEN = __ENV.AUTH_TOKEN || '';

// Custom metrics
const serverErrors = new Counter('server_errors_total');
const conflictResponses = new Counter('conflict_409_total');
const successfulEnrollments = new Counter('successful_enrollments');
const nonceRejections = new Counter('nonce_rejections');
const nonceAcceptances = new Counter('nonce_acceptances');
const serverErrorRate = new Rate('server_error_rate');

// ---------------------------------------------------------------------------
// Thresholds — zero 500-level errors across all scenarios
// ---------------------------------------------------------------------------

export const options = {
  thresholds: {
    server_error_rate: ['rate==0'],            // No 500s anywhere
    server_errors_total: ['count==0'],         // Redundant safety net
    http_req_duration: ['p(95)<5000'],         // 95th percentile under 5s
  },

  scenarios: {
    // Scenario 1: Double Enrollment
    double_enrollment: {
      executor: 'shared-iterations',
      vus: 10,
      iterations: 10,
      maxDuration: '5s',
      exec: 'doubleEnrollment',
      tags: { scenario: 'double_enrollment' },
      startTime: '0s',
    },

    // Scenario 2: Nonce Replay
    nonce_replay: {
      executor: 'constant-vus',
      vus: 5,
      duration: '5s',
      exec: 'nonceReplay',
      tags: { scenario: 'nonce_replay' },
      startTime: '6s', // after enrollment finishes
    },

    // Scenario 3: Parallel Deletes
    parallel_deletes: {
      executor: 'constant-vus',
      vus: 5,
      duration: '5s',
      exec: 'parallelDeletes',
      tags: { scenario: 'parallel_deletes' },
      startTime: '12s',
    },

    // Scenario 4: Settings Race
    settings_race: {
      executor: 'constant-vus',
      vus: 5,
      duration: '10s',
      exec: 'settingsRace',
      tags: { scenario: 'settings_race' },
      startTime: '18s',
    },
  },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function baseHeaders() {
  const headers = {
    'Content-Type': 'application/json',
  };
  if (AUTH_TOKEN) {
    headers['Authorization'] = `Bearer ${AUTH_TOKEN}`;
  }
  return headers;
}

function trackServerError(res) {
  const isServerError = res.status >= 500;
  serverErrorRate.add(isServerError);
  if (isServerError) {
    serverErrors.add(1);
    console.error(
      `[500 ERROR] ${res.request.method} ${res.request.url} => ${res.status}: ${res.body}`
    );
  }
}

// ---------------------------------------------------------------------------
// Scenario 1: Double Enrollment
// ---------------------------------------------------------------------------
// All 10 VUs simultaneously POST to enroll the same participant.
// Expected: exactly 1 succeeds (200/201), the rest get 409 Conflict.
// No 500-level errors should occur.
// ---------------------------------------------------------------------------

const SHARED_PARTICIPANT_ID = 'race-test-participant-shared';

export function doubleEnrollment() {
  group('Double Enrollment Race', () => {
    const url = `${BASE_URL}/chronicle/v3/study/${STUDY_ID}/participants`;
    const payload = JSON.stringify({
      participantId: SHARED_PARTICIPANT_ID,
      datasources: {},
    });

    const res = http.post(url, payload, {
      headers: baseHeaders(),
      tags: { name: 'enroll_participant' },
    });

    trackServerError(res);

    if (res.status === 200 || res.status === 201) {
      successfulEnrollments.add(1);
    }
    if (res.status === 409) {
      conflictResponses.add(1);
    }

    check(res, {
      'enrollment: status is 200, 201, or 409 (no server error)': (r) =>
        r.status === 200 || r.status === 201 || r.status === 409,
      'enrollment: no 500-level error': (r) => r.status < 500,
    });
  });
}

// ---------------------------------------------------------------------------
// Scenario 2: Nonce Replay
// ---------------------------------------------------------------------------
// All VUs send requests with the exact same HMAC nonce. The
// MobileApiSignatureFilter uses putIfAbsent to store nonces, so at most one
// request should be accepted when HMAC enforcement is active (Phase 2).
//
// Phase 1 (accept unsigned): all requests may succeed because signature
//   validation is lenient. The nonce store still records the nonce but does
//   not reject replays when enforcement is off.
// Phase 2 (reject unsigned): exactly 1 accepted, rest rejected with 401/403.
// ---------------------------------------------------------------------------

const FIXED_NONCE = 'fixed-test-nonce-12345';

export function nonceReplay() {
  group('Nonce Replay Attack', () => {
    const url = `${BASE_URL}/chronicle/v3/study/${STUDY_ID}/participants`;
    const now = new Date().toISOString();

    const headers = Object.assign({}, baseHeaders(), {
      'X-Chronicle-Nonce': FIXED_NONCE,
      'X-Chronicle-Timestamp': now,
      'X-Chronicle-Signature': 'test',
    });

    const res = http.get(url, {
      headers: headers,
      tags: { name: 'nonce_replay' },
    });

    trackServerError(res);

    if (res.status === 401 || res.status === 403) {
      nonceRejections.add(1);
    } else if (res.status >= 200 && res.status < 300) {
      nonceAcceptances.add(1);
    }

    check(res, {
      'nonce replay: no 500-level error': (r) => r.status < 500,
      // When HMAC enforcement is active, replayed nonces should be rejected.
      // When HMAC is not enforced (Phase 1), all requests may succeed — this
      // is expected and the check is informational.
      'nonce replay: rejected or accepted (informational)': (r) =>
        r.status === 200 ||
        r.status === 401 ||
        r.status === 403,
    });
  });
}

// ---------------------------------------------------------------------------
// Scenario 3: Parallel Deletes
// ---------------------------------------------------------------------------
// All VUs DELETE the same participant concurrently.
// Expected: first delete succeeds (200/204), subsequent deletes get 404.
// No 500-level errors should occur — the backend must handle the race
// gracefully (idempotent or proper conflict detection).
// ---------------------------------------------------------------------------

const DELETE_PARTICIPANT_ID = 'race-test-delete-target';

export function parallelDeletes() {
  group('Parallel Deletes', () => {
    const url = `${BASE_URL}/chronicle/v3/study/${STUDY_ID}/participants/${DELETE_PARTICIPANT_ID}`;

    const res = http.del(url, null, {
      headers: baseHeaders(),
      tags: { name: 'delete_participant' },
    });

    trackServerError(res);

    check(res, {
      'delete: status is 200, 204, or 404 (graceful)': (r) =>
        r.status === 200 || r.status === 204 || r.status === 404,
      'delete: no 500-level error': (r) => r.status < 500,
    });
  });
}

// ---------------------------------------------------------------------------
// Scenario 4: Settings Race
// ---------------------------------------------------------------------------
// Two groups of VUs update study settings with different values simultaneously.
// VUs 1-2 write "value_A", VUs 3-5 write "value_B". After the burst, the
// final state should be consistent (one of the two values, not a corrupted
// merge). No 500-level errors should occur.
// ---------------------------------------------------------------------------

export function settingsRace() {
  group('Settings Race Condition', () => {
    const url = `${BASE_URL}/chronicle/v3/study/${STUDY_ID}/settings`;

    // Split VUs into two competing groups
    const isGroupA = (__VU % 2 === 0);
    const settingsValue = isGroupA ? 'value_A' : 'value_B';
    const iteration = __ITER;

    const payload = JSON.stringify({
      '@class': 'com.openlattice.chronicle.settings.StudySetting',
      settings: {
        raceTestField: settingsValue,
        raceTestIteration: iteration,
        raceTestVU: __VU,
      },
    });

    const res = http.put(url, payload, {
      headers: baseHeaders(),
      tags: { name: 'update_settings' },
    });

    trackServerError(res);

    check(res, {
      'settings: status is 200 or 204 (accepted)': (r) =>
        r.status === 200 || r.status === 204,
      'settings: no 500-level error': (r) => r.status < 500,
    });

    // Verify consistency: read back and ensure no corruption
    const getRes = http.get(url, {
      headers: baseHeaders(),
      tags: { name: 'read_settings' },
    });

    trackServerError(getRes);

    if (getRes.status === 200) {
      check(getRes, {
        'settings read: valid JSON response': (r) => {
          try {
            JSON.parse(r.body);
            return true;
          } catch (e) {
            return false;
          }
        },
        'settings read: no corrupted/partial data': (r) => {
          try {
            const body = JSON.parse(r.body);
            // If raceTestField exists, it must be one of the two valid values
            if (body.settings && body.settings.raceTestField) {
              return (
                body.settings.raceTestField === 'value_A' ||
                body.settings.raceTestField === 'value_B'
              );
            }
            return true; // field not present is also acceptable
          } catch (e) {
            return false;
          }
        },
      });
    }
  });
}

// ---------------------------------------------------------------------------
// Summary handler — print a human-readable race condition report
// ---------------------------------------------------------------------------

export function handleSummary(data) {
  const out = [];
  out.push('');
  out.push('='.repeat(72));
  out.push('  Chronicle Race Condition Test Results');
  out.push('='.repeat(72));

  // Server errors
  const totalServerErrors = data.metrics.server_errors_total
    ? data.metrics.server_errors_total.values.count
    : 0;
  out.push(`  Server Errors (500+):  ${totalServerErrors}`);

  // Enrollment
  const enrollments = data.metrics.successful_enrollments
    ? data.metrics.successful_enrollments.values.count
    : 0;
  const conflicts = data.metrics.conflict_409_total
    ? data.metrics.conflict_409_total.values.count
    : 0;
  out.push('');
  out.push('  [Scenario 1] Double Enrollment');
  out.push(`    Successful enrollments: ${enrollments} (expected: 1)`);
  out.push(`    Conflict responses:     ${conflicts} (expected: 9)`);
  if (enrollments === 1) {
    out.push('    Result: PASS — exactly one enrollment succeeded');
  } else if (enrollments === 0) {
    out.push('    Result: WARN — no enrollments succeeded (check study/auth config)');
  } else {
    out.push(`    Result: FAIL — ${enrollments} enrollments succeeded (race condition!)`);
  }

  // Nonce replay
  const accepted = data.metrics.nonce_acceptances
    ? data.metrics.nonce_acceptances.values.count
    : 0;
  const rejected = data.metrics.nonce_rejections
    ? data.metrics.nonce_rejections.values.count
    : 0;
  out.push('');
  out.push('  [Scenario 2] Nonce Replay');
  out.push(`    Accepted: ${accepted}`);
  out.push(`    Rejected: ${rejected}`);
  if (rejected > 0 && accepted <= 1) {
    out.push('    Result: PASS — HMAC enforcement is active, replays rejected');
  } else if (accepted > 1 && rejected === 0) {
    out.push('    Result: INFO — HMAC enforcement not active (Phase 1)');
    out.push('      All requests accepted. This is expected when HMAC');
    out.push('      enforcement is disabled. Enable Phase 2 to test replay');
    out.push('      rejection via MobileApiSignatureFilter.putIfAbsent().');
  } else {
    out.push('    Result: WARN — mixed acceptance/rejection, review logs');
  }

  // Parallel deletes
  out.push('');
  out.push('  [Scenario 3] Parallel Deletes');
  out.push(`    Server errors: ${totalServerErrors === 0 ? '0 (PASS)' : totalServerErrors + ' (FAIL)'}`);

  // Settings race
  out.push('');
  out.push('  [Scenario 4] Settings Race');
  out.push(`    Server errors: ${totalServerErrors === 0 ? '0 (PASS)' : totalServerErrors + ' (FAIL)'}`);

  out.push('');
  out.push('='.repeat(72));
  out.push('');

  return {
    stdout: out.join('\n'),
  };
}
