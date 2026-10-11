import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { SharedArray } from 'k6/data';
import { randomBytes } from 'k6/crypto';

/**
 * Chronicle Load Test
 *
 * Validates whether Chronicle can handle 1000 concurrent devices
 * uploading usage events every minute with optional sensor batches.
 *
 * Usage:
 *   DEVICE_FIXTURES_FILE=/private/synthetic-devices.json STUDY_ID=<uuid> k6 run tests/load/chronicle-load-test.js
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
const STUDY_ID = __ENV.STUDY_ID;
const MAX_VUS = Number(__ENV.MAX_VUS || '1000');
if (!Number.isInteger(MAX_VUS) || MAX_VUS <= 0) throw new Error('MAX_VUS must be a positive integer');
const UPLOAD_INTERVAL_SECONDS = Number(__ENV.UPLOAD_INTERVAL_SECONDS || '60');
if (!Number.isFinite(UPLOAD_INTERVAL_SECONDS) || UPLOAD_INTERVAL_SECONDS <= 0) {
  throw new Error('UPLOAD_INTERVAL_SECONDS must be positive');
}

if (!STUDY_ID) {
  throw new Error('STUDY_ID env var is required. Pass the UUID of an existing study.');
}
if (!__ENV.DEVICE_FIXTURES_FILE) throw new Error('DEVICE_FIXTURES_FILE must contain enrolled synthetic devices');
const devices = new SharedArray('synthetic devices', () => JSON.parse(open(__ENV.DEVICE_FIXTURES_FILE)));

const CHRONICLE_BASE = `${BASE_URL}/chronicle/v4/study/${encodeURIComponent(STUDY_ID)}`;

// ---------------------------------------------------------------------------
// Custom metrics
// ---------------------------------------------------------------------------

const uploadDuration = new Trend('upload_duration', true);
const sensorUploadDuration = new Trend('sensor_upload_duration', true);
const uploadErrors = new Rate('upload_errors');
const sensorUploadErrors = new Rate('sensor_upload_errors');
const eventsUploaded = new Counter('events_uploaded');
const samplesUploaded = new Counter('samples_uploaded');

const responseClasses = new Counter('response_classes');

function recordResponse(response, surface) {
  const status = response.status;
  const outcome = status >= 200 && status < 300 ? 'accepted'
    : status === 429 ? 'throttled'
    : status === 401 || status === 403 ? 'authentication_failed'
    : status >= 500 ? 'server_failed'
    : status === 0 ? 'transport_failed' : 'request_rejected';
  const tags = { surface, outcome };
  responseClasses.add(1, tags);
  return check(response, { 'request accepted': () => outcome === 'accepted' }, tags);
}

// ---------------------------------------------------------------------------
// Ramp-up stages
// ---------------------------------------------------------------------------

export const options = {
  stages: [
    // Phase 1: Initial device cohort
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

    // Error rate thresholds
    upload_errors: ['rate<0.01'],
    sensor_upload_errors: ['rate<0.01'],

    // Global
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
  },
};

// ---------------------------------------------------------------------------
// Data generators
// ---------------------------------------------------------------------------

function generateUsageEventBatch(count, participantId) {
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
      '@class': 'com.openlattice.chronicle.android.ChronicleUsageEvent',
      studyId: STUDY_ID,
      participantId,
      appPackageName: packages[i % packages.length],
      interactionType: i % 2 === 0 ? 'Move to Foreground' : 'Move to Background',
      eventType: i % 2 === 0 ? 1 : 2,
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
  const sensorTypes = ['accelerometer', 'gyroscope', 'light', 'proximity'];

  for (let i = 0; i < count; i++) {
    const id = Array.from(new Uint8Array(randomBytes(16)), byte => byte.toString(16).padStart(2, '0')).join('');
    samples.push({
      id: `${id.slice(0, 8)}-${id.slice(8, 12)}-${id.slice(12, 16)}-${id.slice(16, 20)}-${id.slice(20)}`,
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

// ---------------------------------------------------------------------------
// Test scenarios
// ---------------------------------------------------------------------------

function uploadUsageEvents(device, batchSize, headers) {
  const url = `${CHRONICLE_BASE}/participant/${encodeURIComponent(device.participant_id)}/android`;
  const events = generateUsageEventBatch(batchSize, device.participant_id);
  const payload = JSON.stringify(events);

  const res = http.post(url, payload, {
    headers,
    tags: { name: 'upload_usage' },
  });

  uploadDuration.add(res.timings.duration);

  const ok = recordResponse(res, 'usage');

  uploadErrors.add(!ok);
  if (ok) eventsUploaded.add(batchSize);
  return ok;
}

function uploadSensorData(device, batchSize, headers) {
  const url = `${CHRONICLE_BASE}/participant/${encodeURIComponent(device.participant_id)}/android/sensors`;
  const samples = generateSensorDataBatch(batchSize);
  const payload = JSON.stringify(samples);

  const res = http.post(url, payload, {
    headers,
    tags: { name: 'upload_sensors' },
  });

  sensorUploadDuration.add(res.timings.duration);

  const ok = recordResponse(res, 'sensors');

  sensorUploadErrors.add(!ok);
  if (ok) samplesUploaded.add(batchSize);
  return ok;
}

// ---------------------------------------------------------------------------
// Main VU function
// ---------------------------------------------------------------------------

export function setup() {
  if (devices.length < MAX_VUS || devices.some(device =>
    ['participant_id', 'device_id', 'api_key'].some(key =>
      typeof device[key] !== 'string' || !device[key].trim() || /[\r\n]/.test(device[key])))) {
    throw new Error('one enrolled synthetic device with participant_id, device_id and api_key is required per VU');
  }
  if (new Set(devices.map(device => device.api_key)).size !== devices.length) {
    throw new Error('synthetic device credentials must be distinct');
  }
}

export default function () {
  const started = Date.now();
  const device = devices[__VU - 1];
  const headers = { 'Content-Type': 'application/json', 'X-Api-Key': device.api_key,
    'X-Chronicle-Device-Id': device.device_id };

  // All iterations: upload data
  group('usage_event_upload', () => {
    uploadUsageEvents(device, 10, headers);
  });

  // 30% of iterations also upload sensor data
  if (Math.random() < 0.3) {
    group('sensor_data_upload', () => {
    uploadSensorData(device, 500, headers);
    });
  }

  sleep(Math.max(0, UPLOAD_INTERVAL_SECONDS - (Date.now() - started) / 1000));
}

export function handleSummary(data) {
  const summary = {
    timestamp: new Date().toISOString(),
    thresholds_passed: Object.values(data.metrics || {}).every(metric =>
      Object.values(metric.thresholds || {}).every(threshold => threshold.ok)),
    metrics: {
      upload_p50: data.metrics?.upload_duration?.values?.['p(50)'],
      upload_p95: data.metrics?.upload_duration?.values?.['p(95)'],
      upload_p99: data.metrics?.upload_duration?.values?.['p(99)'],
      sensor_p95: data.metrics?.sensor_upload_duration?.values?.['p(95)'],
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
