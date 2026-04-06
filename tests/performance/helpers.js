import http from 'k6/http';
import { check } from 'k6';

/**
 * Shared helpers for Chronicle k6 performance tests.
 *
 * All scripts source BASE_URL and JWT_TOKEN from environment variables.
 */

export const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:40320';
export const JWT_TOKEN = __ENV.JWT_TOKEN || '';

export const HEALTH_URL = `${BASE_URL}/actuator/health`;
export const STUDY_LIST_URL = `${BASE_URL}/chronicle/v3/study`;

export function authHeaders() {
  return {
    Authorization: `Bearer ${JWT_TOKEN}`,
    'Content-Type': 'application/json',
  };
}

export function publicHeaders() {
  return {
    'Content-Type': 'application/json',
  };
}

/**
 * Hit the Spring Boot Actuator health endpoint (unauthenticated).
 * Returns the http response.
 */
export function checkHealth(tags) {
  const res = http.get(HEALTH_URL, {
    tags: Object.assign({ name: 'health' }, tags),
  });
  check(res, {
    'health: status 200': (r) => r.status === 200,
    'health: status is UP': (r) => {
      try {
        return JSON.parse(r.body).status === 'UP';
      } catch {
        return false;
      }
    },
  });
  return res;
}

/**
 * List studies (authenticated). Returns the http response.
 */
export function listStudies(tags) {
  const res = http.get(STUDY_LIST_URL, {
    headers: authHeaders(),
    tags: Object.assign({ name: 'list_studies' }, tags),
  });
  check(res, {
    'list studies: status 200': (r) => r.status === 200,
    'list studies: is array': (r) => {
      try {
        return Array.isArray(JSON.parse(r.body));
      } catch {
        return false;
      }
    },
  });
  return res;
}

/**
 * Get study detail by ID (authenticated).
 */
export function getStudy(studyId, tags) {
  const res = http.get(`${BASE_URL}/chronicle/v3/study/${encodeURIComponent(studyId)}`, {
    headers: authHeaders(),
    tags: Object.assign({ name: 'get_study' }, tags),
  });
  check(res, {
    'study detail: status 200': (r) => r.status === 200,
  });
  return res;
}

/**
 * Get participants for a study (authenticated).
 */
export function getParticipants(studyId, tags) {
  const res = http.get(
    `${BASE_URL}/chronicle/v3/study/${encodeURIComponent(studyId)}/participants`,
    {
      headers: authHeaders(),
      tags: Object.assign({ name: 'get_participants' }, tags),
    },
  );
  check(res, {
    'participants: status 200 or 403': (r) => r.status === 200 || r.status === 403,
  });
  return res;
}

/**
 * Get participant stats for a study (authenticated).
 */
export function getParticipantStats(studyId, tags) {
  const res = http.get(
    `${BASE_URL}/chronicle/v3/study/${encodeURIComponent(studyId)}/participants/stats`,
    {
      headers: authHeaders(),
      tags: Object.assign({ name: 'get_participant_stats' }, tags),
    },
  );
  check(res, {
    'participant stats: status 200 or 403': (r) => r.status === 200 || r.status === 403,
  });
  return res;
}

/**
 * Upload Android usage events via v4 API.
 */
export function uploadAndroidUsageEvents(studyId, participantId, sourceDeviceId, events, tags) {
  const url = `${BASE_URL}/chronicle/v4/study/${encodeURIComponent(studyId)}/participant/${encodeURIComponent(participantId)}/android`;
  const payload = JSON.stringify(events);
  const hdrs = Object.assign({}, authHeaders(), {
    'X-Chronicle-Device-Id': sourceDeviceId,
  });

  const res = http.post(url, payload, {
    headers: hdrs,
    tags: Object.assign({ name: 'upload_android_usage' }, tags),
  });
  check(res, {
    'upload usage: status 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  return res;
}

/**
 * Upload Android sensor data via v4 API.
 */
export function uploadAndroidSensorData(studyId, participantId, sourceDeviceId, samples, tags) {
  const url = `${BASE_URL}/chronicle/v4/study/${encodeURIComponent(studyId)}/participant/${encodeURIComponent(participantId)}/android/sensors`;
  const payload = JSON.stringify(samples);
  const hdrs = Object.assign({}, authHeaders(), {
    'X-Chronicle-Device-Id': sourceDeviceId,
  });

  const res = http.post(url, payload, {
    headers: hdrs,
    tags: Object.assign({ name: 'upload_android_sensors' }, tags),
  });
  check(res, {
    'upload sensors: status 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  return res;
}

/**
 * Enroll a participant device via v4 API.
 */
export function enrollDevice(studyId, participantId, sourceDeviceId, deviceInfo, tags) {
  const url = `${BASE_URL}/chronicle/v4/study/${encodeURIComponent(studyId)}/participant/${encodeURIComponent(participantId)}/enroll`;
  const payload = JSON.stringify(deviceInfo);
  const hdrs = Object.assign({}, authHeaders(), {
    'X-Chronicle-Device-Id': sourceDeviceId,
  });

  const res = http.post(url, payload, {
    headers: hdrs,
    tags: Object.assign({ name: 'enroll_device' }, tags),
  });
  check(res, {
    'enroll: status 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  return res;
}

// ---------------------------------------------------------------------------
// Data generators
// ---------------------------------------------------------------------------

export function generateUsageEventBatch(count) {
  const events = [];
  const now = Date.now();
  const packages = [
    'com.android.chrome',
    'com.whatsapp',
    'com.instagram.android',
    'com.twitter.android',
    'com.spotify.music',
    'com.google.android.youtube',
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

export function generateSensorDataBatch(count) {
  const samples = [];
  const now = Date.now();
  const sensors = ['ACCELEROMETER', 'GYROSCOPE', 'LIGHT', 'PROXIMITY'];

  for (let i = 0; i < count; i++) {
    samples.push({
      sensor: sensors[i % sensors.length],
      timestamp: new Date(now - (count - i) * 20).toISOString(),
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

export function generateAndroidDevice(sourceDeviceId) {
  return {
    deviceId: sourceDeviceId,
    model: 'Pixel 7',
    brand: 'Google',
    device: 'panther',
    product: 'panther',
    osVersion: '14',
    sdkVersion: '34',
  };
}
