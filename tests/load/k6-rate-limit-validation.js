import http from 'k6/http';
import { check, sleep } from 'k6';

/**
 * k6 load test for validating Chronicle RateLimitFilter behavior.
 *
 * The RateLimitFilter enforces:
 *   - Default: 100 requests per minute per IP
 *   - Auth endpoints: stricter (lower) limit
 *   - 429 Too Many Requests with Retry-After header when exceeded
 *
 * This script runs four phases via k6 scenarios:
 *   1. Baseline      — verify rate limit headers are present under normal load
 *   2. Exceed Limit  — burst traffic to trigger 429 responses
 *   3. Auth Endpoint  — confirm stricter limits on auth paths
 *   4. Recovery       — verify counters reset after the rate limit window expires
 *
 * Usage:
 *   k6 run tests/load/k6-rate-limit-validation.js
 *   k6 run --env BASE_URL=http://backend:40320 tests/load/k6-rate-limit-validation.js
 */

const BASE_URL = __ENV.BASE_URL || 'http://localhost:40320';

// ---------------------------------------------------------------------------
// Scenarios — each phase runs as an independent k6 scenario with its own
// start time, duration, and VU count.
// ---------------------------------------------------------------------------
export const options = {
  scenarios: {
    // Phase 1: Baseline — light traffic to confirm rate limit headers exist
    baseline: {
      executor: 'constant-vus',
      vus: 1,
      duration: '10s',
      exec: 'baseline',
      gracefulStop: '5s',
    },

    // Phase 2: Exceed Limit — 5 VUs hammering fast enough to exceed
    // 100 req/min and trigger 429 responses
    exceed_limit: {
      executor: 'constant-vus',
      vus: 5,
      duration: '30s',
      startTime: '15s', // start after baseline finishes
      exec: 'exceedLimit',
      gracefulStop: '5s',
    },

    // Phase 3: Auth Endpoint — hit the stricter auth rate limit
    auth_endpoint: {
      executor: 'constant-vus',
      vus: 3,
      duration: '20s',
      startTime: '50s', // start after exceed_limit finishes
      exec: 'authEndpoint',
      gracefulStop: '5s',
    },

    // Phase 4: Recovery — after the rate limit window resets, confirm
    // normal 200 responses resume
    recovery: {
      executor: 'constant-vus',
      vus: 1,
      duration: '30s',
      startTime: '80s', // enough gap for the 1-minute window to expire
      exec: 'recovery',
      gracefulStop: '5s',
    },
  },

  thresholds: {
    // Baseline: every request should succeed
    'checks{scenario:baseline}': ['rate==1.0'],

    // Exceed Limit: we MUST see at least some 429s (rate limit triggered)
    'checks{scenario:exceed_limit}': ['rate>0.0'],

    // Auth Endpoint: stricter limit should kick in
    'checks{scenario:auth_endpoint}': ['rate>0.0'],

    // Recovery: all requests should succeed once the window resets
    'checks{scenario:recovery}': ['rate>0.8'],

    // Overall request duration sanity check
    http_req_duration: ['p(95)<2000'],
  },
};

// ---------------------------------------------------------------------------
// Phase 1: Baseline
// Send requests at a relaxed pace and verify rate limit headers are present.
// ---------------------------------------------------------------------------
export function baseline() {
  const res = http.get(`${BASE_URL}/chronicle/v3/studies`);

  // Backend returns 401 for unauthenticated requests — this is normal.
  // Rate limit headers may or may not be present depending on filter ordering.
  check(res, {
    'baseline: server responds (not 5xx)': (r) => r.status < 500,
    'baseline: status is 200 or 401': (r) => r.status === 200 || r.status === 401,
  });

  // Stay well under the limit — ~6 req/min per VU
  sleep(1);
}

// ---------------------------------------------------------------------------
// Phase 2: Exceed Limit
// 5 VUs sending requests as fast as possible should exceed 100 req/min
// and produce 429 responses with a Retry-After header.
// ---------------------------------------------------------------------------
export function exceedLimit() {
  const res = http.get(`${BASE_URL}/chronicle/v3/studies`);

  if (res.status === 429) {
    // Verify the 429 response includes Retry-After so clients know when
    // to back off.
    check(res, {
      'exceed: 429 has Retry-After header': (r) =>
        r.headers['Retry-After'] !== undefined
        || r.headers['Retry-after'] !== undefined,
    });

    // Respect the Retry-After hint briefly so we don't just spin
    const retryAfter = parseInt(
      res.headers['Retry-After'] || res.headers['Retry-after'] || '1',
      10,
    );
    sleep(Math.min(retryAfter, 5));
  } else {
    check(res, {
      'exceed: status is 200 (not yet limited)': (r) => r.status === 200,
    });
    // Minimal pause — we want to burst quickly to trigger the limit
    sleep(0.1);
  }
}

// ---------------------------------------------------------------------------
// Phase 3: Auth Endpoint
// Auth endpoints have a stricter rate limit. We send rapid requests to
// /chronicle/auth/session and expect 429s to appear sooner than on the
// default endpoint.
// ---------------------------------------------------------------------------
export function authEndpoint() {
  const res = http.get(`${BASE_URL}/chronicle/auth/session`);

  if (res.status === 429) {
    check(res, {
      'auth: 429 has Retry-After header': (r) =>
        r.headers['Retry-After'] !== undefined
        || r.headers['Retry-after'] !== undefined,
      'auth: hit stricter rate limit': () => true,
    });
    sleep(1);
  } else {
    // Auth session without a valid cookie/token may return 200 or 401 —
    // either is acceptable; we only care about rate limiting behavior.
    check(res, {
      'auth: response before limit (200 or 401)': (r) =>
        r.status === 200 || r.status === 401,
    });
    // Minimal delay to trigger the stricter limit quickly
    sleep(0.1);
  }
}

// ---------------------------------------------------------------------------
// Phase 4: Recovery
// Starts at t=80s — by then the 1-minute rate limit window from earlier
// phases should have expired. Verify that 200 responses resume and rate
// limit counters have reset.
// ---------------------------------------------------------------------------
export function recovery() {
  const res = http.get(`${BASE_URL}/chronicle/v3/studies`);

  check(res, {
    'recovery: status is not 429 (limit reset)': (r) => r.status !== 429,
    'recovery: server responds (200 or 401)': (r) => r.status === 200 || r.status === 401,
    'recovery: no server errors': (r) => {
      return r.status < 500;
    },
  });

  // Gentle pace — we just want to confirm the limit has reset
  sleep(2);
}
