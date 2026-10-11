#!/usr/bin/env python3
"""Real dashboard session, Android enrollment, uploads and PostgreSQL receipts."""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import http.cookiejar
import hashlib
import json
import os
import secrets
from pathlib import Path
import ssl
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit
import uuid

REQUEST_TIMEOUT_SECONDS = 300
NEAR_LIMIT_BYTES = 9 * 1024 * 1024
LARGE_EXPORT_BYTES = 6 * 1024 * 1024
TRANSFER_CHUNK_BYTES = 64 * 1024
SLOW_TRANSFER_INTERVAL_SECONDS = 0.1
IDLE_GAP_SECONDS = 3
IDLE_FAILURE_DEADLINE_SECONDS = 10
BODY_PROBE_CONTROL_TIMEOUT_SECONDS = 5
BODY_DEADLINE_MIN_ELAPSED_FRACTION = 0.8
BROWSER_BURST_REQUESTS = 12
# Usage events reach chronicle_usage_events through the upload buffer, which the backend's
# MOVE_TO_EVENT_STORAGE task drains 5 minutes after start and every 5 minutes after that.
PERSIST_WAIT_SECONDS = 420
EXPORT_RETRY_SECONDS = 30
UPLOAD_RETRY_INTERVAL_SECONDS = 0.12
DEVICE_HEADER = 'X-Chronicle-Device-Id'
API_KEY_HEADER = 'X-Api-Key'
ENROLLMENT_CODE_HEADER = 'X-Chronicle-Enrollment-Code'
MANIFEST_HEADER = 'X-Chronicle-Manifest-Digest'
TABLES = {'usage': 'chronicle_usage_events', 'sensors': 'android_sensor_data',
          'battery': 'battery_telemetry', 'connectivity-state': 'connectivity_state_events',
          'app-network-usage': 'app_network_usage', 'device-settings': 'device_settings',
          'upload-diagnostics': 'upload_diagnostics', 'availability': 'android_device_sensor_availability',
          'interaction': 'interaction_events', 'audio-activity': 'app_audio_activity',
          'audio-content': 'app_audio_content', 'notification-activity': 'notification_activity',
          'sleep': 'sleep_events', 'activity-recognition': 'activity_recognition_events', 'health-connect': 'health_metrics'}
# Every active Android module that is on by default must be listed: enrollment acknowledges
# exactly the effective enabled set, and unlisted defaults (device_lifecycle, questionnaire) count.
MODULES = ('usage_events', 'device_lifecycle', 'questionnaire', 'sensor_accelerometer', 'battery_telemetry', 'connectivity_state',
           'app_network_usage', 'device_settings', 'upload_telemetry', 'sensor_availability',
           'interaction_events', 'audio_activity', 'audio_content', 'notification_activity',
           'sleep', 'activity_recognition', 'health_connect')


def tls_context(ca):
    # Released dashboard CAs (10.3 and earlier) carry no keyUsage; Python 3.13+ strict mode
    # rejects them while curl, browsers and Android accept them. Chain and hostname still verify.
    context = ssl.create_default_context(cafile=ca)
    context.verify_flags &= ~ssl.VERIFY_X509_STRICT
    return context


def client(ca=None):
    jar = http.cookiejar.CookieJar()
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(jar),
                                      urllib.request.HTTPSHandler(context=tls_context(ca)))


def configure_fixture_address(public, resolve_public):
    endpoint, origin = urlsplit('//' + resolve_public), urlsplit(public)
    if not endpoint.hostname or not endpoint.port:
        raise ValueError('fixture endpoint requires host:port')
    resolve = socket.getaddrinfo
    def fixture_address(host, port, *arguments, **keywords):
        if host == origin.hostname and int(port) == (origin.port or 443):
            host, port = endpoint.hostname, endpoint.port
        return resolve(host, port, *arguments, **keywords)
    socket.getaddrinfo = fixture_address


def request(opener, url, method='GET', body=None, headers=None, expected=(200, 201, 204), padding_bytes=0, body_interval=0):
    headers = dict(headers or {})
    if body is not None:
        headers['Content-Type'] = 'application/json'
    data = json.dumps(body).encode() if body is not None else None
    if padding_bytes:
        data += b" " * max(0, padding_bytes - len(data))
    if body_interval:
        headers['Content-Length'] = str(len(data))
        payload = data
        def chunks():
            for offset in range(0, len(payload), TRANSFER_CHUNK_BYTES):
                yield payload[offset:offset + TRANSFER_CHUNK_BYTES]
                time.sleep(body_interval)
        data = chunks()
    with opener.open(urllib.request.Request(url, data, headers, method=method), timeout=REQUEST_TIMEOUT_SECONDS) as response:
        if response.status not in expected:
            raise RuntimeError(f'{method} {url.split("?")[0]} returned {response.status}')
        raw = response.read()
        if not raw:
            return None
        if 'application/json' not in response.headers.get('Content-Type', ''):
            raise RuntimeError('API success did not contain JSON')
        return json.loads(raw)


def probe_body_deadline(origin, ca, deadline_seconds):
    """Trickle an incomplete body with an invalid key: the body is read before key authentication."""
    endpoint = urlsplit(origin)
    connection = socket.create_connection((endpoint.hostname, endpoint.port or (443 if endpoint.scheme == 'https' else 80)), timeout=BODY_PROBE_CONTROL_TIMEOUT_SECONDS)
    if endpoint.scheme == 'https':
        connection = tls_context(ca).wrap_socket(connection, server_hostname=endpoint.hostname)
    connection.settimeout(SLOW_TRANSFER_INTERVAL_SECONDS)
    started = time.monotonic()
    with connection:
        path = '/chronicle/v4/study/00000000-0000-0000-0000-000000000001/participant/deadline-probe/android'
        connection.sendall((f'POST {path} HTTP/1.1\r\nHost: {endpoint.netloc}\r\nContent-Type: application/json\r\n'
                            f'{API_KEY_HEADER}: invalid-deadline-fixture\r\nContent-Length: {NEAR_LIMIT_BYTES}\r\n\r\n[').encode())
        checked_health = False
        while time.monotonic() - started < deadline_seconds + IDLE_FAILURE_DEADLINE_SECONDS:
            try:
                connection.sendall(b' ')
                response = connection.recv(4096)
            except socket.timeout:
                if not checked_health:
                    with client(ca).open(origin.rstrip('/') + '/health', timeout=BODY_PROBE_CONTROL_TIMEOUT_SECONDS) as health:
                        if health.status not in (200, 204):
                            raise RuntimeError('health failed during the partial upload')
                    checked_health = True
                continue
            except (BrokenPipeError, ConnectionResetError, ssl.SSLEOFError):
                response = b''
            elapsed = time.monotonic() - started
            if elapsed < deadline_seconds * BODY_DEADLINE_MIN_ELAPSED_FRACTION:
                raise RuntimeError('upload was rejected before the body deadline; probe did not exercise the body reader')
            if response.startswith(b'HTTP/') and response.split(b' ', 2)[1] == b'401':
                raise RuntimeError('incomplete body reached key authentication')
            print('PASS incomplete trickled body ended at the read deadline; health remained responsive')
            return
    raise RuntimeError('incomplete trickled body exceeded the listener read deadline')


def batches(study, participant, now):
    sample = {'id': str(uuid.uuid4()), 'timestamp': now, 'timezone': 'America/Santiago'}
    return {
        'usage': [{'@class': 'com.openlattice.chronicle.android.ChronicleUsageEvent', 'studyId': study,
                   'participantId': participant, 'appPackageName': 'org.chronicle.smoke', 'interactionType': 'Activity Resumed',
                   'timestamp': now, 'timezone': sample['timezone'], 'user': 'synthetic', 'applicationLabel': 'Smoke'}],
        'sensors': [dict(sample, sensor='accelerometer', x=1.0, y=2.0, z=3.0, accuracy=3)],
        'battery': [dict(sample, levelPercent=80, chargingState='DISCHARGING', plugType='UNPLUGGED',
                         temperatureDeciC=250, voltageMillivolts=4000, health='GOOD')],
        'connectivity-state': [dict(sample, eventType='SNAPSHOT', transport='WIFI', connected=True, metered=False, validated=True)],
        'app-network-usage': [dict(sample, packageName='org.chronicle.smoke', networkType='WIFI', rxBytes=100, txBytes=50,
                                   bucketStartMillis=1, bucketEndMillis=2)],
        'device-settings': [dict(sample, fontScale=1.0, batterySaver=False)],
        'interaction': [dict(sample, eventType='CLICK', gridRows=1, gridCols=1, gridRow=0, gridCol=0,
                             elementRole='android.widget.Button', foregroundPackage='org.chronicle.smoke')],
        'audio-activity': [dict(sample, eventType='SNAPSHOT', audioActive=False)],
        'audio-content': [dict(sample, audioPackage='org.chronicle.smoke', title='Synthetic fixture')],
        'notification-activity': [dict(sample, eventType='POSTED', packageName='org.chronicle.smoke')],
        'sleep': [dict(sample, eventType='CLASSIFY', confidence=80)],
        'activity-recognition': [dict(sample, activityType='STILL', confidence=80)],
        'health-connect': [dict(sample, metricType='STEPS', value=1.0, unit='count', startMillis=1, endMillis=2)],
        'upload-diagnostics': [{'id': sample['id'], 'day': now[:10], 'moduleFamily': 'CONNECTIVITY', 'issueCode': 'TIMEOUT',
                                'count': 1, 'firstOccurredAt': now, 'lastOccurredAt': now}],
    }


def dashboard_client(management, ca, password):
    browser = client(ca)
    browser_headers = {'Origin': management}
    login_url = management + '/chronicle/v3/auth/dashboard-login'
    try:
        login = request(browser, login_url, 'POST', {'password': password}, browser_headers)
    except urllib.error.HTTPError as error:
        # The release drill also seeds a supported predecessor that still has Caddy Basic.
        if error.code != 401 or not error.headers.get('WWW-Authenticate', '').lower().startswith('basic '):
            raise
        basic = base64.b64encode(('researcher:' + password).encode()).decode()
        browser_headers['Authorization'] = 'Basic ' + basic
        login = request(browser, login_url, 'POST', {'password': password}, browser_headers)
    if not login.get('authenticated') or not login.get('csrfToken'):
        raise RuntimeError('dashboard login did not issue an authenticated CSRF session')
    session = request(browser, management + '/chronicle/v3/auth/session', headers=browser_headers)
    if not session.get('authenticated') or not session.get('csrfToken'):
        raise RuntimeError('cookie-backed authenticated follow-up failed')
    # Session bootstrap reissues the CSRF cookie; like the dashboard, send the current token.
    browser_headers['X-CSRF-Token'] = session['csrfToken']
    return browser, browser_headers


def assert_study(records, management, ca, password):
    browser, headers = dashboard_client(management, ca, password)
    study = str(uuid.UUID(records['study']))
    response = request(browser, management + '/chronicle/api/web/study/' + study, headers=headers)
    if response.get('id') != study:
        raise RuntimeError('persisted study was not readable with its researcher permissions')


def create_study(browser, browser_headers, management, now):
    study = request(browser, management + '/chronicle/api/web/study', 'POST',
                    {'title': 'Topology synthetic study', 'contact': 'synthetic@example.org',
                     'modules': {'CHRONICLE_DATA_COLLECTION': {}}, 'startedAt': (now - timedelta(days=1)).isoformat(), 'endedAt': (now + timedelta(days=2)).isoformat()}, browser_headers)
    return str(uuid.UUID(study))


def exercise(public, management, ca, password, transport_recipe=None, enrollment_credentials=None, seed_only=False):
    browser, browser_headers = dashboard_client(management, ca, password)
    phone = client(ca)
    now = datetime.now(timezone.utc)
    study = create_study(browser, browser_headers, management, now)
    base = management + '/chronicle/api/web/study/' + study
    setting_url = base + '/settings/type/DataCollection'
    setting = {'@class': 'com.openlattice.chronicle.collection.AndroidDataCollectionSetting', 'version': 2,
               'modules': {module: {'enabled': True, 'required': False} for module in MODULES}}
    setting['modules']['health_connect']['healthConnectRecordTypes'] = ['steps']
    request(browser, setting_url, 'PATCH', setting, browser_headers)
    fields = ('responsibleInstitution', 'serverOperator', 'researchContact', 'purpose', 'expectedDuration', 'procedures',
              'foreseeableRisks', 'expectedBenefits', 'dataUseAndSharing', 'retentionAndDeletion')
    policy = dict.fromkeys(fields, 'Synthetic release qualification only')
    policy.update({'@class': 'com.openlattice.chronicle.study.StudyParticipantPolicy', 'version': 'smoke-1',
                   'effectiveAt': now.isoformat(), 'privacyPolicyUrl': public + '/chronicle/privacy',
                   'withdrawalUrl': public + '/chronicle/withdraw'})
    request(browser, base + '/settings/type/ParticipantPolicy', 'PATCH', policy, browser_headers)
    participant = 'smoke-' + uuid.uuid4().hex
    request(browser, base + '/participant', 'POST', {'participantId': participant, 'candidate': {},
                                                   'participationStatus': 'ENROLLED'}, browser_headers)
    invitation = request(browser, base + '/participant/' + participant + '/form-access-codes', 'POST',
                         {'formKind': 'ENROLLMENT'}, browser_headers)
    device = str(uuid.uuid4())
    enrollment = public + '/chronicle/v4/study/' + study + '/participant/' + participant
    headers = {DEVICE_HEADER: device, ENROLLMENT_CODE_HEADER: invitation['accessCode']}
    preview = request(phone, enrollment + '/enrollment-preview', headers=headers)
    if preview['manifest']['serverOrigin'].rstrip('/') != public:
        raise RuntimeError('manifest used the wrong canonical origin')
    proposed = uuid.uuid4().hex
    headers.update({MANIFEST_HEADER: preview['manifestDigest'], 'X-Chronicle-Enrollment-Attempt-Id': str(uuid.uuid4()),
                    'X-Chronicle-Proposed-Api-Key': 'ck_' + proposed[:8] + '_' + proposed})
    android = {'@class': 'com.openlattice.chronicle.sources.AndroidDevice', 'deviceId': device, 'sdkVersion': '36', 'osVersion': '16'}
    android.update(dict.fromkeys(('device', 'model', 'codename', 'brand', 'product'), 'synthetic'))
    enrolled = request(phone, enrollment + '/enroll', 'POST', android, headers)
    replay = request(phone, enrollment + '/enroll', 'POST', android, headers)
    if enrolled != replay or not enrolled.get('apiKey'):
        raise RuntimeError('lost enrollment acknowledgement did not replay the same device credential')
    headers = {DEVICE_HEADER: device, API_KEY_HEADER: enrolled['apiKey']}
    if enrollment_credentials:
        credentials_path = Path(enrollment_credentials)
        with credentials_path.open('x') as output:
            credentials_path.chmod(0o600)
            json.dump({'API_KEY': enrolled['apiKey'], 'TEST_STUDY_ID': study,
                       'TEST_PARTICIPANT_ID': participant, 'TEST_DEVICE_ID': device}, output)
    manifest = preview['manifest']
    request(phone, enrollment + '/android/collection-ack', 'POST',
            {'acknowledgedModules': list(MODULES), 'acknowledgedAt': now.isoformat(),
             'settingsVersion': manifest['settingsVersion'], 'disclosureVersion': policy['version'], 'manifestDigest': preview['manifestDigest']}, headers)
    sensor_batch = upload_batches(phone, enrollment, headers, study, participant, now.isoformat(), bool(transport_recipe))
    if not seed_only:
        download = export_download(browser, base, browser_headers, participant)
        if transport_recipe:
            Path(transport_recipe).write_text(json.dumps({'upload': {'url': enrollment + '/android/sensors', 'body': sensor_batch,
                                                                   'headers': headers}, 'download': download,
                                                         'browser': {'url': setting_url, 'headers': download['headers']}}))
            Path(transport_recipe).chmod(0o600)
    return {'study': study, 'participant': participant, 'tables': list(TABLES.values())}


def upload_batches(phone, enrollment, headers, study, participant, now, large_export=False):
    payloads = batches(study, participant, now)
    if large_export:
        # Random-looking printable text avoids turning the streaming test into a tiny gzip.
        payloads['usage'][0]['applicationLabel'] = secrets.token_hex(LARGE_EXPORT_BYTES // 2)
    payloads['availability'] = {'availableSensors': ['accelerometer'], 'unavailableSensors': []}
    for kind, batch in payloads.items():
        path = '/android' + ('' if kind == 'usage' else '/sensors/availability' if kind == 'availability' else '/' + kind)
        first = request(phone, enrollment + path, 'POST', batch, headers, padding_bytes=NEAR_LIMIT_BYTES if kind == 'sensors' else 0)
        request(phone, enrollment + path, 'POST', batch, headers)
        if kind == 'upload-diagnostics':
            if first != [batch[0]['id']]:
                raise RuntimeError('diagnostic upload acknowledgement mismatch')
        elif first != 1:
            raise RuntimeError(f'{kind} upload did not acknowledge one row')
        time.sleep(UPLOAD_RETRY_INTERVAL_SECONDS)
    return payloads['sensors']


def export_download(browser, base, browser_headers, participant):
    deadline = time.monotonic() + PERSIST_WAIT_SECONDS
    while True:
        export = request(browser, base + '/export/async', 'POST',
                         {'dataTypes': ['UsageEvents'], 'participantIds': [participant], 'format': 'CSV'}, browser_headers)
        export_url = base + '/export/' + export['exportId']
        while export['status'] != 'COMPLETED':
            if export['status'] == 'FAILED' or time.monotonic() >= deadline:
                raise RuntimeError('authenticated export did not complete within its deadline')
            time.sleep(1)
            export = request(browser, export_url, headers=browser_headers)
        if export['rowCount'] == 1:
            break
        # Zero rows until the upload buffer drains; any other count is wrong outright.
        if export['rowCount'] != 0 or time.monotonic() >= deadline:
            raise RuntimeError('export omitted the uploaded usage row')
        time.sleep(min(EXPORT_RETRY_SECONDS, deadline - time.monotonic()))
    download = urllib.request.Request(export_url + '/download', headers=browser_headers)
    with browser.open(download,
                      timeout=REQUEST_TIMEOUT_SECONDS) as response:
        if response.status != 200 or b'org.chronicle.smoke' not in response.read():
            raise RuntimeError('authenticated streamed export omitted uploaded data')
    return {'url': download.full_url, 'headers': dict(download.header_items())}


def transport_replay(recipe, ca, idle_failure=False):
    opener = client(ca)
    upload = recipe['upload']
    started = time.monotonic()
    try:
        acknowledged = request(opener, upload['url'], 'POST', upload['body'], upload['headers'],
                               padding_bytes=NEAR_LIMIT_BYTES,
                               body_interval=IDLE_GAP_SECONDS if idle_failure else SLOW_TRANSFER_INTERVAL_SECONDS)
    except (urllib.error.URLError, OSError) as error:
        if not idle_failure or isinstance(error, urllib.error.HTTPError) and error.code not in (408, 504):
            raise
        elapsed = time.monotonic() - started
        if elapsed > IDLE_FAILURE_DEADLINE_SECONDS:
            raise RuntimeError(f'short upstream idle failure was not bounded ({elapsed:.1f}s)') from error
        return
    if idle_failure:
        raise RuntimeError('short upstream idle timeout accepted a stalled upload')
    if acknowledged != 1:
        raise RuntimeError('slow replay did not acknowledge the uploaded row')
    download = recipe['download']
    hashes = []
    for interval in (0, SLOW_TRANSFER_INTERVAL_SECONDS):
        digest, size = hashlib.sha256(), 0
        with opener.open(urllib.request.Request(download['url'], headers=download['headers']), timeout=REQUEST_TIMEOUT_SECONDS) as response:
            if response.status != 200:
                raise RuntimeError('streamed export failed')
            while chunk := response.read(TRANSFER_CHUNK_BYTES):
                digest.update(chunk); size += len(chunk)
                if interval:
                    time.sleep(interval)
        if size < LARGE_EXPORT_BYTES:
            raise RuntimeError('export was too small to qualify streaming')
        hashes.append(digest.digest())
    if hashes[0] != hashes[1]:
        raise RuntimeError('slow export was truncated or changed')

def upload_row_counts(records, query):
    study = str(uuid.UUID(records['study']))
    participant = records['participant']
    if not participant.startswith('smoke-') or not participant[6:].isalnum():
        raise ValueError('receipt is not a synthetic participant')
    counts = {}
    for table in records['tables']:
        if table not in TABLES.values():
            raise ValueError('unknown upload table')
        # chronicle_usage_events keeps study_id as text; the other upload tables use uuid.
        count = query(f"SELECT count(*) FROM {table} WHERE study_id::text='{study}' AND participant_id='{participant}'")
        counts[table] = int(str(count).strip())
    return counts


def assert_persisted(records, query):
    expected = records.get('counts', dict.fromkeys(records['tables'], 1))
    if upload_row_counts(records, query) != expected:
        raise RuntimeError('persisted upload table counts differ from the recorded receipt')


def run_upload_security(public, management, password, credentials, ca, resolve_public, report):
    browser, _ = dashboard_client(management, ca, password)
    token = next((cookie.value for handler in browser.handlers if isinstance(handler, urllib.request.HTTPCookieProcessor)
                  for cookie in handler.cookiejar if cookie.name == 'chronicle_auth'), None)
    if not token:
        raise RuntimeError('dashboard session did not issue an authentication cookie')
    environment = dict(os.environ, **json.loads(Path(credentials).read_text()), BASE_URL=public, NO_PROXY='*',
                       MANAGEMENT_URL=management, AUTH_TOKEN=token)
    if ca:
        environment.update(CURL_CA_BUNDLE=ca, CA_CERT=ca, SSL_CERT_FILE=ca)
    if resolve_public:
        origin, endpoint = urlsplit(public), urlsplit('//' + resolve_public)
        environment['UPLOAD_CONNECT_TO'] = f'{origin.hostname}:{origin.port or 443}:{endpoint.hostname}:{endpoint.port}'
    subprocess.run(['bash', str(Path(__file__).resolve().parents[1] / 'security/run-all-security.sh'),
                    'upload', report], env=environment, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--public')
    parser.add_argument('--management')
    parser.add_argument('--ca')
    parser.add_argument('--records', required=True)
    parser.add_argument('--seed-only', action='store_true', help='Seed enrollment and uploads without export or security checks')
    parser.add_argument('--assert-db', action='store_true')
    parser.add_argument('--assert-study', action='store_true')
    parser.add_argument('--create-study', action='store_true')
    parser.add_argument('--capture-db', action='store_true', help='Record upload-table counts before restoring')
    parser.add_argument('--enrollment-credentials', help='Private fixture credentials; never upload as an artifact')
    parser.add_argument('--upload-security-report', help='Run the upload security layer after enrolling')
    parser.add_argument('--project')
    parser.add_argument('--resolve-public', help='Fixture transport endpoint; TLS still validates the public hostname')
    parser.add_argument('--ipv4', action='store_true')
    parser.add_argument('--transport-recipe', help='Private synthetic transfer recipe; never upload as an artifact')
    parser.add_argument('--transport-replay', action='store_true')
    parser.add_argument('--idle-failure', action='store_true')
    parser.add_argument('--browser-burst', action='store_true')
    parser.add_argument('--body-deadline-test-seconds', type=float)
    args = parser.parse_args()
    if args.seed_only and (args.upload_security_report is not None or args.transport_recipe is not None):
        parser.error('--seed-only cannot be combined with --upload-security-report or --transport-recipe')
    if args.resolve_public:
        configure_fixture_address(args.public, args.resolve_public)
    if args.ipv4:
        resolve_ipv4 = socket.getaddrinfo
        socket.getaddrinfo = lambda host, port, *arguments, **keywords: [
            address for address in resolve_ipv4(host, port, *arguments, **keywords) if address[0] == socket.AF_INET]
    if args.body_deadline_test_seconds is not None:
        for origin in (args.public, args.management):
            probe_body_deadline(origin, args.ca, args.body_deadline_test_seconds)
        return
    if args.transport_replay:
        recipe = json.loads(Path(args.transport_recipe).read_text())
        if args.browser_burst:
            browser = client(args.ca)
            for _ in range(BROWSER_BURST_REQUESTS):
                request(browser, recipe['browser']['url'], headers=recipe['browser']['headers'])
            print('PASS browser session burst through shared VPN NAT')
            return
        transport_replay(recipe, args.ca, args.idle_failure)
        print('PASS bounded short-idle failure' if args.idle_failure else 'PASS slow near-limit replay and complete large export')
        return
    if args.upload_security_report:
        # Its probes add rows for the enrolled participant, so it runs after the receipt counts are asserted.
        if not args.enrollment_credentials:
            raise ValueError('upload security requires --enrollment-credentials')
        run_upload_security(args.public, args.management, sys.stdin.readline().rstrip('\n'), args.enrollment_credentials,
                            args.ca, args.resolve_public, args.upload_security_report)
        print('PASS upload security layer')
        return
    if args.create_study:
        browser, headers = dashboard_client(args.management, args.ca, sys.stdin.readline().rstrip('\n'))
        study = create_study(browser, headers, args.management, datetime.now(timezone.utc))
        Path(args.records).write_text(json.dumps({'study': study}))
        print('PASS API created a study with researcher permissions')
        return
    if args.assert_study:
        assert_study(json.loads(Path(args.records).read_text()), args.management, args.ca, sys.stdin.readline().rstrip('\n'))
        print('PASS study and researcher permissions survived backend restart')
        return
    if args.assert_db or args.capture_db:
        records = json.loads(Path(args.records).read_text())
        def query(sql):
            result = subprocess.run(['docker', 'compose', '-p', args.project, 'exec', '-T', 'postgres', '/bin/bash', '-ceu',
                                     'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -qAt -v ON_ERROR_STOP=1 -h 127.0.0.1 '
                                     '-U "${POSTGRES_USER:-chronicle}" -d "${POSTGRES_DB:-chronicle}" -f -'],
                                    input=sql, capture_output=True, text=True, timeout=REQUEST_TIMEOUT_SECONDS, check=True)
            return result.stdout
        if args.capture_db:
            records['counts'] = upload_row_counts(records, query)
            Path(args.records).write_text(json.dumps(records))
            print('PASS captured upload-table counts for restore verification')
            return
        deadline = time.monotonic() + PERSIST_WAIT_SECONDS
        while True:
            try:
                assert_persisted(records, query)
                break
            except RuntimeError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(2)
    else:
        records = exercise(args.public, args.management, args.ca, sys.stdin.readline().rstrip('\n'), args.transport_recipe,
                           args.enrollment_credentials, args.seed_only)
        Path(args.records).write_text(json.dumps(records))
    print('PASS real enrollment, upload contracts and receipts' if args.assert_db else 'PASS dashboard session, enrollment and uploads')


if __name__ == '__main__':
    main()
