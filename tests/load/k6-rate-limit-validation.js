import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

// Run against a quiet disposable backend with empty buckets and no proxy throttling.
const BASE = __ENV.BASE_URL || 'http://localhost:40320';
const DEFAULT_LIMIT = Number(__ENV.DEFAULT_LIMIT || 100);
const AUTH_LIMIT = Number(__ENV.AUTH_LIMIT || 10);
const BURST_MULTIPLIER = Number(__ENV.BURST_MULTIPLIER || 1.5);
const WINDOW_SECONDS = 60;
const throttled = new Counter('throttled');
if (!__ENV.AUTH_TOKEN || AUTH_LIMIT >= DEFAULT_LIMIT || AUTH_LIMIT <= 0 || BURST_MULTIPLIER < 1) {
  throw new Error('Provide AUTH_TOKEN and the configured default/auth limits and burst multiplier');
}
export const options = {
  scenarios: {
    default_burst: { executor: 'shared-iterations', vus: 1, iterations: 1, exec: 'defaultBurst', maxDuration: '30s' },
    auth_burst: { executor: 'shared-iterations', vus: 1, iterations: 1, exec: 'authBurst', startTime: '35s', maxDuration: '30s' },
  },
  thresholds: {
    checks: ['rate==1'],
    'throttled{tier:default}': ['count==1'],
    'throttled{tier:auth}': ['count==1'],
  },
};
function burst(tier, limit, send) {
  const started = Date.now();
  const capacity = Math.floor(limit * BURST_MULTIPLIER);
  // The bounded request budget includes at most one window of greedy refill.
  for (let index = 1; index <= capacity + limit + 1; index++) {
    const response = send();
    check(response, { 'advertised limit matches configuration': r => Number(r.headers['X-Ratelimit-Limit']) === limit });
    if (response.status === 429) {
      throttled.add(1, { tier });
      const refill = Math.ceil((Date.now() - started) / 1000 * limit / WINDOW_SECONDS);
      check(response, {
        'first rejection occurs at configured burst capacity': () => index >= capacity + 1 && index <= capacity + refill + 1,
        'Retry-After is a positive number': r => Number(r.headers['Retry-After']) > 0,
      });
      return;
    }
    check(response, { 'positive control reaches the production handler': r => r.status === 200 });
  }
  check(false, { 'burst must observe throttling': value => value });
}
export function defaultBurst() {
  burst('default', DEFAULT_LIMIT, () => http.post(`${BASE}/chronicle/v3/authorizations`, '[]', {
    headers: { Authorization: `Bearer ${__ENV.AUTH_TOKEN}`, 'Content-Type': 'application/json' },
  }));
}
export function authBurst() {
  burst('auth', AUTH_LIMIT, () => http.get(`${BASE}/chronicle/v3/auth/session`));
}
