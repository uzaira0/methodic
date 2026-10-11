import http from 'k6/http';
import crypto from 'k6/crypto';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

// Disposable study with participant disclosures configured and no other traffic.
const BASE = __ENV.BASE_URL || 'http://localhost:40320';
const RESEARCHER_API = __ENV.MANAGEMENT_URL ? __ENV.MANAGEMENT_URL + '/chronicle/api/web' : BASE + '/chronicle/v3';
const STUDY = __ENV.STUDY_ID;
const DEVICE = __ENV.TEST_DEVICE_ID;
const CONCURRENCY = 10;
const signingEnabled = Boolean(__ENV.MOBILE_SIGNING_SECRET);
const races = signingEnabled ? ['enrollment', 'nonce', 'deletion', 'settings'] : ['enrollment', 'deletion', 'settings'];
const operations = new Counter('operations');
const nonceAccepted = new Counter('nonce_accepted');
const nonceRejected = new Counter('nonce_rejected');
const settingsCommitted = new Counter('settings_committed');
const settingsRejected = new Counter('settings_rejected');
const headers = { Authorization: `Bearer ${__ENV.AUTH_TOKEN}`, 'Content-Type': 'application/json' };
if (!STUDY || !DEVICE || !__ENV.AUTH_TOKEN) {
  throw new Error('STUDY_ID, TEST_DEVICE_ID and AUTH_TOKEN are required');
}
export const options = {
  scenarios: Object.fromEntries(races.map((operation, index) => [operation, {
    executor: 'per-vu-iterations', vus: CONCURRENCY, iterations: 1, exec: operation,
    startTime: `${index * 10}s`, maxDuration: '10s', gracefulStop: '0s',
  }])),
  thresholds: Object.assign({
    checks: ['rate==1'],
    settings_committed: ['count==1'],
    settings_rejected: [`count==${CONCURRENCY - 1}`],
  }, Object.fromEntries(races.map(operation => [
    `operations{operation:${operation}}`, [`count==${CONCURRENCY}`],
  ])), signingEnabled ? { nonce_accepted: ['count==1'], nonce_rejected: [`count==${CONCURRENCY - 1}`] } : {}),
};
if (__ENV.UPLOAD_CONNECT_TO) {
  const mapping = __ENV.UPLOAD_CONNECT_TO.match(/^(\[[^\]]+\]:\d+|[^:]+:\d+):(\[[^\]]+\]:\d+|[^:]+:\d+)$/);
  if (!mapping) throw new Error('UPLOAD_CONNECT_TO requires host:port:host:port');
  options.hosts = { [mapping[1]]: mapping[2] };
}
function control(response, label) {
  if (!check(response, { [label]: r => r.status === 200 || r.status === 201 })) throw new Error(label);
  return response.json();
}
function signedHeaders(path, nonce, timestamp) {
  const canonical = ['POST', path, timestamp, nonce, crypto.sha256('[]', 'hex')].join('|');
  return Object.assign({}, headers, { 'X-Chronicle-Nonce': nonce,
    'X-Chronicle-Timestamp': timestamp,
    'X-Chronicle-Signature': crypto.hmac('sha256', __ENV.MOBILE_SIGNING_SECRET, canonical, 'base64') });
}
export function setup() {
  if (!signingEnabled) console.log('Nonce replay race is not applicable because legacy mobile signing is disabled.');
  const study = `${RESEARCHER_API}/study/${STUDY}`;
  control(http.get(study, { headers }), 'researcher can read the fixture study');
  const participant = `race-${Date.now()}`;
  control(http.post(`${study}/participant`, JSON.stringify({ participantId: participant, candidate: {},
    participationStatus: 'ENROLLED' }), { headers }), 'register a real disposable participant');
  const invitation = control(http.post(`${study}/participant/${participant}/form-access-codes`,
    JSON.stringify({ formKind: 'ENROLLMENT' }), { headers }), 'issue an enrollment invitation');
  const mobile = `${BASE}/chronicle/v4/study/${STUDY}/participant/${participant}`;
  const enrollHeaders = { 'Content-Type': 'application/json', 'X-Chronicle-Device-Id': DEVICE,
    'X-Chronicle-Enrollment-Code': invitation.accessCode };
  const preview = control(http.get(`${mobile}/enrollment-preview`, { headers: enrollHeaders }), 'preview invitation');
  const random = Array.from(new Uint8Array(crypto.randomBytes(16)), byte => byte.toString(16).padStart(2, '0')).join('');
  const nonce = random.replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5');
  const apiKey = `ck_${random.slice(0, 8)}_${random}`;
  Object.assign(enrollHeaders, { 'X-Chronicle-Manifest-Digest': preview.manifestDigest,
    'X-Chronicle-Enrollment-Attempt-Id': DEVICE, 'X-Chronicle-Proposed-Api-Key': apiKey });
  const device = { '@class': 'com.openlattice.chronicle.sources.AndroidDevice', deviceId: DEVICE,
    sdkVersion: '36', osVersion: '16', device: 'synthetic', model: 'synthetic', codename: 'synthetic', brand: 'synthetic', product: 'synthetic' };
  const body = JSON.stringify(device);
  const enrollment = control(http.post(`${mobile}/enroll`, body, { headers: enrollHeaders }), 'valid enrollment control');
  if (enrollment.apiKey !== apiKey) throw new Error('enrollment did not bind the proposed credential');
  control(http.post(`${mobile}/android/collection-ack`, JSON.stringify({
    acknowledgedModules: Object.keys(preview.manifest.collectionSettings.modules).filter(module => preview.manifest.collectionSettings.modules[module].enabled),
    acknowledgedAt: new Date().toISOString(), settingsVersion: preview.manifest.settingsVersion,
    disclosureVersion: preview.manifest.participantPolicy.version, manifestDigest: preview.manifestDigest,
  }), { headers: { 'Content-Type': 'application/json', 'X-Api-Key': apiKey, 'X-Chronicle-Device-Id': DEVICE } }), 'record fixture consent');
  const path = `/chronicle/v3/study/${STUDY}/participant/${participant}/android/${DEVICE}/sensors`;
  const timestamp = String(Math.floor(Date.now() / 1000));
  if (signingEnabled) {
    control(http.post(BASE + path, '[]', { headers: signedHeaders(path, DEVICE, timestamp) }), 'valid signed replay control');
  }
  const settingsUrl = `${study}/settings/type/DataCollection`;
  const settingsResponse = http.get(settingsUrl, { headers });
  const setting = control(settingsResponse, 'read authoritative settings');
  if (!settingsResponse.headers.Etag) throw new Error('settings positive control has no revision ETag');
  return { study, mobile, participant, enrollHeaders, body, apiKey, path,
    replayHeaders: signingEnabled ? signedHeaders(path, nonce, timestamp) : null, setting,
    settingsUrl, revision: settingsResponse.headers.Etag };
}
export function enrollment(data) {
  const response = http.post(`${data.mobile}/enroll`, data.body, { headers: data.enrollHeaders });
  check(response, { 'concurrent enrollment retries return the same credential': r => r.status === 200 && r.json().apiKey === data.apiKey });
  if (response.status === 200) operations.add(1, { operation: 'enrollment' });
}
export function nonce(data) {
  const response = http.post(BASE + data.path, '[]', { headers: data.replayHeaders });
  check(response, { 'valid signed replay is accepted once or rejected as replay': r => r.status === 200 || r.status === 401 });
  if (response.status === 200) nonceAccepted.add(1);
  if (response.status === 401) nonceRejected.add(1);
  if (response.status === 200 || response.status === 401) operations.add(1, { operation: 'nonce' });
}
export function deletion(data) {
  const response = http.del(`${data.study}/participants`, JSON.stringify([data.participant]), { headers });
  check(response, { 'parallel erasure scheduling returns operation IDs': r => r.status === 200 && Array.isArray(r.json()) && r.json().length === 1 });
  if (response.status === 200) operations.add(1, { operation: 'deletion' });
}
export function settings(data) {
  const response = http.patch(data.settingsUrl, JSON.stringify(data.setting), { headers: Object.assign({}, headers, { 'If-Match': data.revision }) });
  check(response, { 'concurrent revision writes succeed or report a stale revision': r => r.status === 200 || r.status === 412 });
  if (response.status === 200) settingsCommitted.add(1);
  if (response.status === 412) settingsRejected.add(1);
  if (response.status === 200 || response.status === 412) operations.add(1, { operation: 'settings' });
}
