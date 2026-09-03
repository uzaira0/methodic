import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { randomString } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

/**
 * Chronicle Load Test
 *
 * Validates whether Chronicle can handle 1000 concurrent devices
 * uploading usage events and sensor data every 15 minutes.
 *
 * Usage:
 *   k6 run --env JWT_TOKEN=<token> --env STUDY_ID=<uuid> tests/load/chronicle-load-test.js
 *
 * Optional env vars:
 *   BASE_URL  - Chronicle server URL (default: http://127.0.0.1:40320)
 *   MAX_VUS   - Peak virtual users (default: 1000)
 *   STUDY_ID  - UUID of the study to test against (required)
 */

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:40320';
const JWT_TOKEN = __ENV.JWT_TOKEN;
const STUDY_ID = __ENV.STUDY_ID;
const MAX_VUS = parseInt(__ENV.MAX_VUS || '1000', 10);

if (!JWT_TOKEN) {
  throw new Error('JWT_TOKEN env var is required. Generate with: docker/generate-jwt.sh');
}
if (!STUDY_ID) {
  throw new Error('STUDY_ID env var is required. Pass the UUID of an existing study.');
}

const CHRONICLE_BASE = `${BASE_URL}/chronicle/v4/study/${STUDY_ID}`;

const headers = {
  Authorization: `Bearer ${JWT_TOKEN}`,
  'Content-Type': 'application/json',
};

// ---------------------------------------------------------------------------
// Custom metrics
// ---------------------------------------------------------------------------

const enrollmentDuration = new Trend('enrollment_duration', true);
const uploadDuration = new Trend('upload_duration', true);
const sensorUploadDuration = new Trend('sensor_upload_duration', true);
const enrollmentErrors = new Rate('enrollment_errors');
const uploadErrors = new Rate('upload_errors');
const sensorUploadErrors = new Rate('sensor_upload_errors');
const eventsUploaded = new Counter('events_uploaded');
const samplesUploaded = new Counter('samples_uploaded');

// ---------------------------------------------------------------------------
// Ramp-up stages
// ---------------------------------------------------------------------------

export const options = {
  stages: [
    // Phase 1: Enrollment burst
    { duration: '30s', target: Math.min(100, MAX_VUS) },
    { duration: '30s', target: Math.min(100, MAX_VUS) },

    // Phase 2: Steady usage event uploads
    { duration: '1m', target: Math.min(500, MAX_VUS) },
    { duration: '1m', target: Math.min(500, MAX_VUS) },

    // Phase 3: Peak load — mixed uploads
    { duration: '1m', target: MAX_VUS },
    { duration: '1m', target: MAX_VUS },

    // Phase 4: Cooldown
    { duration: '30s', target: 0 },
  ],

  thresholds: {
    // Upload latency thresholds
    upload_duration: ['p(95)<500', 'p(99)<2000'],
    sensor_upload_duration: ['p(95)<500', 'p(99)<2000'],
    enrollment_duration: ['p(95)<1000'],

    // Error rate thresholds
    upload_errors: ['rate<0.01'],
    sensor_upload_errors: ['rate<0.01'],
    enrollment_errors: ['rate<0.05'],  // enrollment may fail for duplicates

    // Global
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
  },
};

// ---------------------------------------------------------------------------
// Data generators
// ---------------------------------------------------------------------------

function generateParticipantId(vuId) {
  return `loadtest-${vuId}-${randomString(8)}`;
}

function generateSourceDeviceId() {
  return `device-${randomString(16)}`;
}

function generateUsageEventBatch(count) {
  const events = [];
  const now = Date.now();
  const packages = [
    'com.android.chrome',
    'com.whatsapp',
    'com.instagram.android',
    'com.twitter.android',
    'com.spotify.music',
    'com.google.android.youtube',
    'com.snapchat.android',
    'com.facebook.katana',
    'com.tiktok.android',
    'org.telegram.messenger',
  ];

  for (let i = 0; i < count; i++) {
    events.push({
      appPackageName: packages[i % packages.length],
      interactionType: i % 2 === 0 ? 'Foreground' : 'Background',
      eventType: 1,
      timestamp: new Date(now - (count - i) * 60000).toISOString(),
      timezone: 'America/New_York',
      user: 'user0',
      applicationLabel: packages[i % packages.length].split('.').pop(),
    });
  }
  return events;
}

function generateSensorDataBatch(count) {
  const samples = [];
  const now = Date.now();
  const sensorTypes = ['ACCELEROMETER', 'GYROSCOPE', 'LIGHT', 'PROXIMITY'];

  for (let i = 0; i < count; i++) {
    samples.push({
      id: crypto.randomUUID ? crypto.randomUUID() : `${randomString(8)}-${randomString(4)}-${randomString(4)}-${randomString(4)}-${randomString(12)}`,
      sensor: sensorTypes[i % sensorTypes.length],
      timestamp: new Date(now - (count - i) * 20).toISOString(),  // 20ms apart for sensor data
      timezone: 'America/New_York',
      x: Math.random() * 10 - 5,
      y: Math.random() * 10 - 5,
      z: Math.random() * 10 - 5,
      w: null,
      accuracy: 3,
    });
  }
  return samples;
}

function generateAndroidDevice(sourceDeviceId) {
  return {
    deviceId: sourceDeviceId,
    model: 'Pixel 7',
    brand: 'Google',
    device: 'panther',
    product: 'panther',
    osVersion: '14',
    sdkVersion: '34',
    fcmRegistrationToken: `fake-fcm-token-${randomString(32)}`,
  };
}

// ---------------------------------------------------------------------------
// Test scenarios
// ---------------------------------------------------------------------------

function enrollParticipant(participantId, sourceDeviceId) {
  const url = `${CHRONICLE_BASE}/participant/${participantId}/enroll`;
  const payload = JSON.stringify(generateAndroidDevice(sourceDeviceId));

  const res = http.post(url, payload, {
    headers,
    tags: { name: 'enroll' },
  });

  enrollmentDuration.add(res.timings.duration);

  const ok = check(res, {
    'enroll: status 2xx': (r) => r.status >= 200 && r.status < 300,
  });

  enrollmentErrors.add(!ok);
  return ok;
}

function uploadUsageEvents(participantId, sourceDeviceId, batchSize) {
  const url = `${CHRONICLE_BASE}/participant/${participantId}/android`;
  const events = generateUsageEventBatch(batchSize);
  const payload = JSON.stringify(events);

  const res = http.post(url, payload, {
    headers: Object.assign({}, headers, { 'X-Source-Device-Id': sourceDeviceId }),
    tags: { name: 'upload_usage' },
  });

  uploadDuration.add(res.timings.duration);

  const ok = check(res, {
    'upload: status 2xx': (r) => r.status >= 200 && r.status < 300,
  });

  uploadErrors.add(!ok);
  if (ok) eventsUploaded.add(batchSize);
  return ok;
}

function uploadSensorData(participantId, sourceDeviceId, batchSize) {
  const url = `${CHRONICLE_BASE}/participant/${participantId}/android/sensors`;
  const samples = generateSensorDataBatch(batchSize);
  const payload = JSON.stringify(samples);

  const res = http.post(url, payload, {
    headers: Object.assign({}, headers, { 'X-Source-Device-Id': sourceDeviceId }),
    tags: { name: 'upload_sensors' },
  });

  sensorUploadDuration.add(res.timings.duration);

  const ok = check(res, {
    'sensor upload: status 2xx': (r) => r.status >= 200 && r.status < 300,
  });

  sensorUploadErrors.add(!ok);
  if (ok) samplesUploaded.add(batchSize);
  return ok;
}

// ---------------------------------------------------------------------------
// Main VU function
// ---------------------------------------------------------------------------

export function setup() {
  // Verify the study exists before starting
  const res = http.get(`${BASE_URL}/chronicle/v3/study/${STUDY_ID}`, { headers });
  check(res, {
    'setup: study exists': (r) => r.status === 200,
  });
  if (res.status !== 200) {
    throw new Error(`Study ${STUDY_ID} not found (status ${res.status}). Create it before running the load test.`);
  }
  return { studyId: STUDY_ID };
}

export default function (data) {
  const vuId = __VU;
  const iterationId = __ITER;

  // Each VU represents a unique device
  const participantId = `loadtest-vu${vuId}`;
  const sourceDeviceId = `device-vu${vuId}`;

  // First iteration: enroll
  if (iterationId === 0) {
    group('enrollment', () => {
      enrollParticipant(participantId, sourceDeviceId);
    });
    sleep(0.5);
  }

  // All iterations: upload data
  group('usage_event_upload', () => {
    uploadUsageEvents(participantId, sourceDeviceId, 10);
  });

  // 30% of iterations also upload sensor data
  if (Math.random() < 0.3) {
    group('sensor_data_upload', () => {
      uploadSensorData(participantId, sourceDeviceId, 500);
    });
  }

  // Simulate 15-minute upload interval compressed: sleep 1-3s between iterations
  sleep(1 + Math.random() * 2);
}

export function handleSummary(data) {
  const summary = {
    timestamp: new Date().toISOString(),
    thresholds_passed: Object.values(data.root_group?.checks || {}).every(c => c.passes > 0),
    metrics: {
      upload_p50: data.metrics?.upload_duration?.values?.['p(50)'],
      upload_p95: data.metrics?.upload_duration?.values?.['p(95)'],
      upload_p99: data.metrics?.upload_duration?.values?.['p(99)'],
      sensor_p95: data.metrics?.sensor_upload_duration?.values?.['p(95)'],
      enrollment_p95: data.metrics?.enrollment_duration?.values?.['p(95)'],
      error_rate: data.metrics?.http_req_failed?.values?.rate,
      total_requests: data.metrics?.http_reqs?.values?.count,
      throughput_rps: data.metrics?.http_reqs?.values?.rate,
      events_uploaded: data.metrics?.events_uploaded?.values?.count,
      samples_uploaded: data.metrics?.samples_uploaded?.values?.count,
    },
  };

  return {
    stdout: JSON.stringify(summary, null, 2) + '\n',
    'load-test-results.json': JSON.stringify(summary, null, 2),
  };
}
