import gzip
import importlib.util
import io
import json
import os
import re
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'selfhost'))
from chronicle_ops import common, dump, receipts, reconcile, release, verify
from test_restore import DUMP

client_spec = importlib.util.spec_from_file_location('topology_client', ROOT / 'tests/deployment/selfhost-client.py')
client = importlib.util.module_from_spec(client_spec)
client_spec.loader.exec_module(client)
POSTGRES_INSPECTION = {'Config': {'Env': ['PGDATA=/data/db']},
                       'Mounts': [{'Destination': '/data/db', 'Source': '/database'},
                                  {'Destination': '/var/lib/postgresql/tde-keyring', 'Source': '/keyring'}]}


class TopologyTests(unittest.TestCase):
    def test_webhook_runbook_describes_the_authenticated_api_and_enrollment_fence(self):
        section = (ROOT / 'selfhost/docs/CONFIGURATION.md').read_text().split('## Study webhook recipients', 1)[1].split('\n## ', 1)[0]
        api = (ROOT / 'chronicle-api/src/main/kotlin/com/openlattice/chronicle/webhooks/WebhookApi.kt').read_text()
        webhook_path = re.search(r'WEBHOOKS_PATH: String = "([^"]+)"', api)[1]
        self.assertRegex(section, r'GET /[^`\s]+' + re.escape(webhook_path) + r'`')
        for policy in ('authenticated API', 'before enrollment', 'active or pending', 'are audited', 'recipient-side deletion'):
            self.assertIn(policy, section)

    def test_internal_login_migrates_existing_settings_and_refuses_missing_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            host = Path(folder)
            overlay = 'overlays/mode-behind-proxy-internal.yml'
            (host / overlay).parent.mkdir(); (host / overlay).touch(); (host / 'docker-compose.yml').touch()
            path = host / '.env'
            legacy = f"COMPOSE_FILE=docker-compose.yml:{overlay}\nTESTING_LOGIN_ENABLED=true\nREQUIRE_MFA=false\n"
            path.write_text(legacy); path.chmod(0o600)
            with self.assertRaisesRegex(ValueError, 'run ./chronicle setup'):
                release.migrate_dashboard_login(host)
            self.assertEqual(path.read_text(), legacy)
            path.write_text(legacy + "DASHBOARD_PASSWORD_HASH='$2b$synthetic'\n")
            self.assertTrue(release.migrate_dashboard_login(host))
            self.assertFalse(release.migrate_dashboard_login(host))
            settings = release.read_env(path)
            self.assertEqual(settings['TESTING_LOGIN_ENABLED'], 'false')
            self.assertEqual(settings['REQUIRE_MFA'], 'false')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with patch('chronicle_ops.release.write_text') as write:
                release.merge_env(dict(settings, TESTING_LOGIN_ENABLED='true'), path.read_text(), host / 'candidate', host, [overlay])
            self.assertIn('TESTING_LOGIN_ENABLED=false\n', write.call_args.args[1])
        snippets = (ROOT / 'selfhost/caddy/snippets.caddy').read_text()
        self.assertNotIn('basic_auth', snippets)
        self.assertIn('remote_ip', snippets)
        cli = (ROOT / 'selfhost/chronicle').read_text()
        for name, end in (('cmd_up()', 'cmd_down()'), ('cmd_reconcile()', 'cmd_deletion_status()')):
            self.assertIn('dashboard-login-migrate', cli.split(name, 1)[1].split(end, 1)[0])

    def test_every_shipped_caddy_listener_has_a_finite_body_read_deadline(self):
        snippets = (ROOT / 'selfhost/caddy/snippets.caddy').read_text()
        body_mib = int(re.search(r'max_size (\d+)MiB', snippets)[1])
        deadline = int(re.search(r'read_body (\d+)s', snippets)[1])
        self.assertGreater(deadline, 0)
        self.assertLessEqual(body_mib * 1024 / deadline, 35, 'deadline must allow a 35 KiB/s mobile upload')
        for file in (ROOT / 'selfhost').rglob('Caddyfile*'):
            self.assertRegex(file.read_text(), r'servers\s*\{\s*import chronicle_listener_timeouts')
        drill = (ROOT / 'tests/deployment/selfhost-topology.sh').read_text()
        self.assertIn('--body-deadline-test-seconds', drill)
        self.assertIn('transfer_client phone-a\n', drill)

    def test_container_structure_job_targets_the_three_shipped_selfhost_images(self):
        import yaml
        job = (ROOT / 'scripts/local-ci.sh').read_text().split('job_container_structure() {', 1)[1].split('\n}', 1)[0]
        self.assertIn('for component in frontend caddy backup', job)
        self.assertIn('--config "$ROOT_DIR/tests/container/frontend-prod.yaml"', job)
        for component in ('frontend', 'caddy', 'backup'):
            config = yaml.safe_load((ROOT / f'tests/container/selfhost-{component}.yaml').read_text())
            self.assertEqual(config['schemaVersion'], '2.0.0')
            self.assertTrue(config['commandTests'])
            self.assertTrue(config['fileExistenceTests'])

    def test_shipped_mapstores_persist_and_api_study_is_read_after_restart(self):
        import yaml
        for name in ('selfhost/config/rhizome.yaml.template',
                     'docker/rhizome-docker.yaml.template', 'docker/hetzner/rhizome-runtime.yaml.template',
                     'chronicle-server/src/main/resources/rhizome.yaml'):
            self.assertIs(yaml.safe_load((ROOT / name).read_text())['enable-persistence'], True, name)
        smoke = (ROOT / 'tests/smoke/selfhost-release-smoke.sh').read_text()
        self.assertLess(smoke.index('--create-study'), smoke.index('docker compose restart backend'))
        self.assertLess(smoke.index('docker compose restart backend'), smoke.index('--assert-study'))
        study = '00000000-0000-0000-0000-000000000001'
        with patch.object(client, 'dashboard_client', return_value=(object(), {})), \
             patch.object(client, 'request', return_value={'id': study}) as request:
            client.assert_study({'study': study}, 'https://management.example', None, 'synthetic')
            self.assertTrue(request.call_args.args[1].endswith('/chronicle/api/web/study/' + study))
            request.return_value = {'id': 'wrong'}
            with self.assertRaises(RuntimeError):
                client.assert_study({'study': study}, 'https://management.example', None, 'synthetic')

    def test_release_smoke_honors_explicit_reconciliation_override(self):
        source = (ROOT / 'tests/smoke/selfhost-release-smoke.sh').read_text()
        setting = next(line for line in source.splitlines() if line.startswith('export CHRONICLE_RECONCILE_ENABLED='))
        for value in ('true', 'false', None):
            env = dict(os.environ)
            env.pop('CHRONICLE_RECONCILE_ENABLED', None)
            if value is not None:
                env['CHRONICLE_RECONCILE_ENABLED'] = value
            result = subprocess.run(['bash', '-euc', setting + '\nprintf "%s" "$CHRONICLE_RECONCILE_ENABLED"'],
                                    env=env, capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout, value or 'false')

    def test_load_smoke_uses_enrolled_identity_current_payloads_and_requires_acknowledgment(self):
        source = (ROOT / 'tests/load/smoke-test.sh').read_text().split("<<'PY_SMOKE'\n", 1)[1].split('\nPY_SMOKE', 1)[0]
        requests = []
        result_count = 1
        def upload(_phone, path, method, rows, headers):
            self.assertEqual(method, 'POST')
            requests.append((path, headers, rows))
            return result_count
        fixture = {'batches': client.batches, 'client': lambda _ca: object(), 'request': upload,
                   'configure_fixture_address': client.configure_fixture_address,
                   'API_KEY_HEADER': client.API_KEY_HEADER, 'DEVICE_HEADER': client.DEVICE_HEADER}
        env = dict(BASE_URL='https://fixture.example', API_KEY='synthetic-enrolled-key',
                   UPLOAD_CONNECT_TO='fixture.example:443:127.0.0.1:9443',
                   TEST_STUDY_ID='00000000-0000-0000-0000-000000000001', TEST_PARTICIPANT_ID='enrolled-participant', TEST_DEVICE_ID='registered-device')
        for accepted in (1, 0):
            result_count = accepted
            requests.clear()
            with patch.dict(os.environ, env), patch('sys.argv', ['smoke', str(ROOT)]), \
                 patch('runpy.run_path', return_value=fixture), patch('sys.stdout', io.StringIO()), \
                 patch.object(client.socket, 'getaddrinfo', return_value=[]) as resolve:
                if accepted: exec(compile(source, 'smoke-test.sh', 'exec'), {})
                else:
                    with self.assertRaisesRegex(SystemExit, 'did not acknowledge'):
                        exec(compile(source, 'smoke-test.sh', 'exec'), {})
                client.socket.getaddrinfo('fixture.example', 443)
                resolve.assert_called_once_with('127.0.0.1', 9443)
                client.socket.getaddrinfo('management.example', 443)
                self.assertEqual(resolve.call_args.args, ('management.example', 443))
            self.assertTrue(requests)
            for path, headers, rows in requests:
                self.assertNotIn('Authorization', headers)
                self.assertEqual(headers['X-Api-Key'], env['API_KEY'])
                self.assertEqual(headers['X-Chronicle-Device-Id'], env['TEST_DEVICE_ID'])
                self.assertIn('/participant/enrolled-participant/android', path)
                if path.endswith('/sensors'):
                    self.assertEqual(rows[0]['sensor'], 'accelerometer')
                else:
                    self.assertEqual(rows[0]['@class'], 'com.openlattice.chronicle.android.ChronicleUsageEvent')
                    self.assertEqual(rows[0]['studyId'], env['TEST_STUDY_ID'])
                    self.assertEqual(rows[0]['participantId'], env['TEST_PARTICIPANT_ID'])
            if accepted: self.assertEqual(len(requests), 2)

    def test_strict_hmac_needs_credentials_and_a_valid_signed_positive_control(self):
        source = (ROOT / 'tests/security/test-hmac-enforcement.sh').read_text().split("<<'PY_HMAC'\n", 1)[1].split('\nPY_HMAC', 1)[0]
        with patch.dict(os.environ, {'STRICT': '1'}, clear=True), patch('urllib.request.urlopen') as transport:
            with self.assertRaisesRegex(SystemExit, 'Strict mode requires'):
                exec(compile(source, 'test-hmac-enforcement.sh', 'exec'), {})
            transport.assert_not_called()
        import urllib.error
        attempts = []
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def read(self): return b'{}'
        def transport(request, **_):
            attempts.append(request)
            if len(attempts) == 1: return Response()
            message = 'Missing required signature headers' if len(attempts) == 2 else 'Request replay detected'
            raise urllib.error.HTTPError(request.full_url, 401, 'fixture', {}, io.BytesIO(json.dumps({'error': message}).encode()))
        env = {'STRICT': '1', 'MOBILE_SIGNING_SECRET': 'synthetic-signing-secret', 'TEST_DEVICE_ID': 'fixture-device',
               'HMAC_TEST_PATH': '/chronicle/v4/study/fixture/participant/fixture/enroll', 'MOBILE_ENROLLMENT_BODY': '{}'}
        with patch.dict(os.environ, env, clear=True), patch('urllib.request.urlopen', side_effect=transport), patch('sys.stdout', io.StringIO()):
            exec(compile(source, 'test-hmac-enforcement.sh', 'exec'), {})
        self.assertEqual(len(attempts), 3)
        self.assertEqual(attempts[0].data, attempts[2].data)
        self.assertEqual(attempts[0].headers, attempts[2].headers)
        self.assertNotIn('X-chronicle-signature', attempts[1].headers)
        with patch.dict(os.environ, env, clear=True), patch('urllib.request.urlopen', side_effect=urllib.error.HTTPError('fixture', 500, 'fixture', {}, io.BytesIO(b'{}'))), patch('sys.stdout', io.StringIO()):
            with self.assertRaises(SystemExit) as rejected:
                exec(compile(source, 'test-hmac-enforcement.sh', 'exec'), {})
            self.assertEqual(rejected.exception.code, 1)

    def test_monitoring_siblings_cannot_reach_backend_or_hazelcast(self):
        import yaml
        base = yaml.safe_load((ROOT / 'selfhost/docker-compose.yml').read_text())
        overlay = yaml.safe_load((ROOT / 'selfhost/overlays/monitoring.yml').read_text())
        backend = set(base['services']['backend'].get('networks', ['default']))
        for service in ('grafana', 'cadvisor', 'fluent-bit', 'victoriametrics', 'victorialogs',
                        'metrics-exporter', 'operational-probe', 'monitoring-config', 'docker-socket-proxy'):
            self.assertFalse(backend.intersection(overlay['services'][service].get('networks', ['default'])), service)
        self.assertEqual(set(base['services']['postgres']['networks']) &
                         set(overlay['services']['operational-probe']['networks']), {'database-probe'})
        self.assertIn('monitoring', overlay['networks'])
        proxy = (ROOT / 'selfhost/monitoring/backend-metrics.caddy').read_text()
        self.assertIn('@metrics path /prometheus/', proxy)
        self.assertIn('reverse_proxy @metrics https://backend:8443', proxy)
        self.assertIn('respond 404', proxy)
        renderer = (ROOT / 'selfhost/monitoring/render-config.sh').read_text()
        self.assertIn('targets: ["web:9091"]', renderer)
        config = yaml.safe_load((ROOT / 'selfhost/config/rhizome.yaml.template').read_text())
        self.assertEqual(config['hazelcast']['interfaces'], ['127.0.0.1'])
        self.assertIn('-Dhazelcast.socket.bind.any=false', (ROOT / 'selfhost/backend-entrypoint.sh').read_text())
        self.assertIn('.setInterfaces( hzConfiguration.getInterfaces() )',
                      (ROOT / 'rhizome/src/main/java/com/geekbeast/rhizome/pods/hazelcast/BaseHazelcastInstanceConfigurationPod.java').read_text())

    def test_overdue_hold_alert_survives_scraping_and_cli_includes_overlapping_holds(self):
        renderer = (ROOT / 'selfhost/monitoring/render-config.sh').read_text()
        keep = re.search(r"regex: '(chronicle_[^']+)'", renderer)[1]
        self.assertIsNotNone(re.fullmatch(keep, 'chronicle_retention_holds_overdue'))
        rules = json.loads((ROOT / 'selfhost/monitoring/grafana-alerting/rules.yml').read_text())['groups'][0]['rules']
        rule = next(rule for rule in rules if rule['uid'] == 'retention-hold-review-overdue')
        self.assertEqual(rule['data'][0]['model']['expr'], 'max(chronicle_retention_holds_overdue)')
        self.assertEqual(rule['data'][2]['model']['expression'], '$B > 0')
        query = (ROOT / 'selfhost/chronicle').read_text().split('cmd_deletion_status() {', 1)[1].split('\ncmd_update()', 1)[0]
        for fragment in ('AS review_overdue', 'min(hold.review_at)', 'hold.released_at IS NULL',
                         'overlap.study_id = operation.study_id', 'overlap.participant_block_token = operation.participant_block_token'):
            self.assertIn(fragment, query)

    def test_enrollment_credentials_are_private_and_upload_layer_uses_them(self):
        study = '00000000-0000-0000-0000-000000000001'
        public = 'https://fixture.example'
        def response(_opener, url, _method='GET', _body=None, _headers=None, **_kwargs):
            if url.endswith('/dashboard-login'): return {'authenticated': True, 'csrfToken': 'login-csrf'}
            # Session bootstrap reissues the CSRF cookie, as the server does.
            if url.endswith('/auth/session'): return {'authenticated': True, 'csrfToken': 'session-csrf'}
            if url.endswith('/web/study'):
                self.assertEqual(_headers['X-CSRF-Token'], 'session-csrf')
                return study
            if url.endswith('/form-access-codes'): return {'accessCode': 'synthetic-invitation'}
            if url.endswith('/enrollment-preview'):
                return {'manifest': {'serverOrigin': public, 'settingsVersion': 1}, 'manifestDigest': 'synthetic-digest'}
            if url.endswith('/enroll'): return {'apiKey': 'synthetic-device-credential'}
            return None
        with tempfile.TemporaryDirectory() as folder:
            credentials = Path(folder) / 'credentials.json'
            with patch.object(client, 'client'), patch.object(client, 'request', side_effect=response), \
                 patch.object(client, 'upload_batches'), patch.object(client, 'export_download'):
                records = client.exercise(public, 'https://management.example', None, 'synthetic-password',
                                          enrollment_credentials=credentials)
            self.assertEqual(credentials.stat().st_mode & 0o777, 0o600)
            fixture = json.loads(credentials.read_text())
            self.assertEqual(fixture['TEST_STUDY_ID'], records['study'])
            self.assertEqual(fixture['TEST_PARTICIPANT_ID'], records['participant'])
            self.assertNotIn('API_KEY', records)
            browser = SimpleNamespace(handlers=[client.urllib.request.HTTPCookieProcessor([
                SimpleNamespace(name='chronicle_auth', value='synthetic-session-jwt')])])
            with patch.object(client.subprocess, 'run') as run, \
                 patch.object(client, 'dashboard_client', return_value=(browser, {})) as login:
                client.run_upload_security(public, 'https://management.example', 'synthetic-password',
                                           credentials, 'fixture-ca.crt', '127.0.0.1:9443', 'report')
            login.assert_called_once_with('https://management.example', 'fixture-ca.crt', 'synthetic-password')
            self.assertEqual(run.call_args.args[0][-2:], ['upload', 'report'])
            self.assertEqual(run.call_args.kwargs['env']['API_KEY'], fixture['API_KEY'])
            self.assertEqual(run.call_args.kwargs['env']['UPLOAD_CONNECT_TO'], 'fixture.example:443:127.0.0.1:9443')
            expected = dict(AUTH_TOKEN='synthetic-session-jwt', MANAGEMENT_URL='https://management.example',
                            CA_CERT='fixture-ca.crt', SSL_CERT_FILE='fixture-ca.crt')
            self.assertEqual({key: run.call_args.kwargs['env'][key] for key in expected}, expected)
            self.assertTrue(run.call_args.kwargs['check'])
        saved = dict(records, counts=dict.fromkeys(records['tables'], 3))
        client.assert_persisted(saved, lambda _sql: '3')
        with self.assertRaises(RuntimeError): client.assert_persisted(saved, lambda _sql: '2')
        smoke = (ROOT / 'tests/smoke/selfhost-release-smoke.sh').read_text()
        self.assertIn('--enrollment-credentials', smoke)
        self.assertIn('--upload-security-report', smoke)
        self.assertIn('--capture-db', smoke)
        restore = smoke[smoke.index('CLEAN_RESTORE_SHA256='):smoke.index('clean_restore_seconds=')]
        self.assertEqual(restore.count('assert_upload_rows'), 2)
        self.assertIn('after-clean-backup', restore)
        self.assertIn('"$post_backup_marker" == 0', restore)

    def test_environment_contract_matches_shell_and_preserves_settings(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'settings'
            path.write_text("export POSTGRES_DB='custom db' # saved\nJWT_SECRET='literal$secret'\nEMPTY= # blank\n")
            settings = release.read_env(path)
            self.assertEqual(release.value(settings, 'POSTGRES_DB'), 'custom db')
            self.assertEqual(release.value(settings, 'JWT_SECRET'), 'literal$secret')
            self.assertEqual(release.value(settings, 'EMPTY'), '')
            shell = subprocess.run(['bash', '-c', 'source "$1"; printf "%s" "$POSTGRES_DB"', 'fixture', str(path)], capture_output=True, text=True, check=True)
            self.assertEqual(shell.stdout, release.value(settings, 'POSTGRES_DB'))
            text = release.merge_env(settings, 'POSTGRES_DB=default\nJWT_SECRET=new\n', None, folder, ['docker-compose.yml'], preserve_images=True)
            path.write_text(text)
            self.assertEqual(release.value(release.read_env(path), 'POSTGRES_DB'), 'custom db')
            for invalid in ('POSTGRES_DB=$(id)', 'POSTGRES_DB=x\nPOSTGRES_DB=y', 'source other',
                            'POSTGRES_DB=x;touch /tmp/unwanted', 'POSTGRES_DB=x|cat',
                            'POSTGRES_DB="literal\\$value"', 'POSTGRES_DB="literal\\nvalue"'):
                path.write_text(invalid)
                with self.assertRaises(ValueError): release.read_env(path)
            for text in ('literal$secret', "operator's state", 'spaces and # punctuation'):
                path.write_text('POSTGRES_DB=' + release.quote_env(text) + ' # ignored " quote\n')
                decoded = release.value(release.read_env(path), 'POSTGRES_DB')
                shell = subprocess.run(['bash', '-c', 'source "$1"; printf "%s" "$POSTGRES_DB"', 'fixture', str(path)], capture_output=True, text=True, check=True)
                self.assertEqual(decoded, text)
                self.assertEqual(shell.stdout, text)

    def test_shared_lock_inherits_and_excludes_other_processes(self):
        with tempfile.TemporaryDirectory() as folder:
            descriptor = common.acquire_operation_lock(folder)
            try:
                self.assertIsNone(common.acquire_operation_lock(folder))
                child = common.run(['python3', '-c', 'from chronicle_ops.common import acquire_operation_lock;import sys;assert acquire_operation_lock(sys.argv[1]) is None', folder],
                                   capture=True, env=dict(os.environ, PYTHONPATH=str(ROOT / 'selfhost')), timeout=5)
                self.assertEqual(child.returncode, 0, child.stderr)
                competing = subprocess.run(['flock', '-n', str(Path(folder) / common.OPERATION_LOCK), 'true'], timeout=5)
                self.assertNotEqual(competing.returncode, 0)
            finally:
                common.release_operation_lock(descriptor)
            self.assertEqual(subprocess.run(['flock', '-n', str(Path(folder) / common.OPERATION_LOCK), 'true'], timeout=5).returncode, 0)

    def test_checkpoint_allows_only_explicit_forward_owner(self):
        with tempfile.TemporaryDirectory() as folder:
            state = Path(folder)
            marker = state / '.chronicle-upgrade.lock'
            marker.mkdir()
            receipts.write_json(marker / 'recovery.json', {'owner': str(state / 'new'), 'phase': 'migration-started'})
            for owner, scheduled, allowed in (('old', 'false', False), ('new', 'true', False), ('new', 'false', True)):
                with self.subTest(owner=owner, scheduled=scheduled), patch.dict(os.environ, CHRONICLE_RECONCILE_RUN=scheduled):
                    if allowed: reconcile.check_mutations(state, state / owner, True)
                    else:
                        with self.assertRaises(ValueError): reconcile.check_mutations(state, state / owner, True)
            (marker / 'recovery.json').write_text('invalid')
            with self.assertRaises(ValueError): reconcile.check_mutations(state, state / 'new', True)

    def test_empty_crontab_forces_locale_and_preserves_docker_environment(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, CHRONICLE_RECONCILE_ENABLED='true', DOCKER_HOST='unix:///run/operator/docker.sock', LC_ALL='es_CL.UTF-8'), \
             patch('chronicle_ops.reconcile.platform.system', return_value='Linux'), patch('chronicle_ops.reconcile.shutil.which', return_value='/bin/tool'), \
             patch('chronicle_ops.reconcile.run', return_value=SimpleNamespace(returncode=1, stdout='', stderr='no crontab for fixture')) as run:
            reconcile.install(Path(folder) / 'chronicle', folder, 'fixture')
            self.assertEqual(run.call_args_list[0].kwargs['env']['LC_ALL'], 'C')
            self.assertIn('unix:///run/operator/docker.sock', (Path(folder) / 'reconcile.sh').read_text())

    def test_storage_checks_docker_and_volume_inodes_before_mutation(self):
        results = [SimpleNamespace(stdout='/docker'), SimpleNamespace(stdout='pg'),
                   SimpleNamespace(stdout=json.dumps([POSTGRES_INSPECTION]))]
        disks = {'/state': SimpleNamespace(f_bavail=20, f_frsize=common.GIB, f_files=100000, f_favail=20000),
                 '/docker': SimpleNamespace(f_bavail=2, f_frsize=common.GIB, f_files=100000, f_favail=20000),
                 '/database': SimpleNamespace(f_bavail=20, f_frsize=common.GIB, f_files=100000, f_favail=2)}
        with patch('chronicle_ops.common.run', side_effect=results) as run, patch('chronicle_ops.common.os.statvfs', side_effect=lambda path: disks[str(path)]):
            rows = common.storage_report('/state', 'fixture')
        self.assertEqual([row[1] for row in rows], [True, False, False])
        self.assertIn('-a', run.call_args_list[1].args[0])

    def test_update_peak_is_reserved_on_image_and_state_devices(self):
        results = [SimpleNamespace(stdout='/docker'), SimpleNamespace(stdout='pg'),
                   SimpleNamespace(stdout=json.dumps([POSTGRES_INSPECTION]))]
        disk = SimpleNamespace(f_bavail=20, f_frsize=common.GIB, f_files=100000, f_favail=20000)
        with patch('chronicle_ops.common.run', side_effect=results), patch('chronicle_ops.common.os.statvfs', return_value=disk):
            rows = common.storage_report('/state', 'fixture', peak_bytes=common.UPDATE_PEAK_BYTES)
        self.assertEqual([row[4] for row in rows], [8 * common.GIB, 8 * common.GIB, 5 * common.GIB])

    def test_storage_probe_uses_read_only_daemon_mount_when_operator_cannot_traverse(self):
        results = [SimpleNamespace(stdout='/docker'), SimpleNamespace(stdout=''), SimpleNamespace(stdout=''),
                   SimpleNamespace(stdout='Filesystem 1024-blocks Used Available Capacity Mounted\ndisk 20000000 1 10000000 1% /storage\nFilesystem Inodes IUsed IFree IUse% Mounted\ndisk 100000 1 99999 1% /storage\n')]
        disk = SimpleNamespace(f_bavail=20, f_frsize=common.GIB, f_files=100000, f_favail=20000)
        with patch('chronicle_ops.common.run', side_effect=results) as run, \
             patch('chronicle_ops.common.os.statvfs', side_effect=[disk, PermissionError(), PermissionError()]), \
             patch.dict(os.environ, POSTGRES_IMAGE='fixture@sha256:'+'a'*64):
            rows = common.storage_report('/state', 'fixture')
        self.assertTrue(all(row[1] for row in rows))
        self.assertIn('type=bind,src=/docker,dst=/storage,readonly', run.call_args.args[0])
        self.assertIn('--read-only', run.call_args.args[0])

    def test_missing_daemon_paths_use_daemon_measurement(self):
        results = [SimpleNamespace(stdout='/docker'), SimpleNamespace(stdout='pg'),
                   SimpleNamespace(stdout=json.dumps([POSTGRES_INSPECTION]))]
        measured = SimpleNamespace(stdout='Filesystem blocks used available percent mount\ndisk 20000000 1 10000000 1% /storage\nFilesystem inodes used available percent mount\ndisk 100000 1 99999 1% /storage\n')
        disk = SimpleNamespace(f_bavail=20, f_frsize=common.GIB, f_files=100000, f_favail=20000)
        with patch.object(common, 'run', side_effect=results + [measured, measured]) as run, \
             patch.object(common.os, 'statvfs', side_effect=[disk, FileNotFoundError(), FileNotFoundError()]), \
             patch.dict(os.environ, POSTGRES_IMAGE='fixture-image'):
            self.assertTrue(all(row[1] for row in common.storage_report('/state', 'fixture')))
        self.assertEqual([call.args[0][call.args[0].index('--mount') + 1] for call in run.call_args_list[-2:]],
                         ['type=bind,src=/docker,dst=/storage,readonly', 'type=bind,src=/database,dst=/storage,readonly'])

    def test_rotation_waits_for_startup_lock_before_loading_configuration(self):
        with tempfile.TemporaryDirectory() as folder:
            state = Path(folder)
            for name in ('rotate-secret.sh', 'network-policy.sh'):
                shutil.copy2(ROOT / 'selfhost' / name, state / name)
            (state / 'chronicle_ops').symlink_to(ROOT / 'selfhost/chronicle_ops', target_is_directory=True)
            settings = state / '.env'; settings.write_text('CHRONICLE_STATE_DIR=.\n'); settings.chmod(0o600)
            tools = state / 'bin'; tools.mkdir()
            (tools / 'docker').write_text('#!/bin/sh\nprintf called >"$DOCKER_LOCK_PROBE"\nexit 17\n')
            (tools / 'docker').chmod(0o700)
            descriptor = common.acquire_operation_lock(state)
            environment = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'], DOCKER_LOCK_PROBE=str(state / 'called'))
            environment.pop(common.LOCK_FD_ENV, None)
            try:
                with subprocess.Popen(['bash', str(state / 'rotate-secret.sh'), '--yes', 'jwt'], env=environment,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
                    try:
                        with self.assertRaises(subprocess.TimeoutExpired): child.communicate(timeout=0.3)
                        self.assertFalse((state / 'called').exists())
                        common.release_operation_lock(descriptor); descriptor = None
                        child.communicate(timeout=10)
                        self.assertTrue((state / 'called').exists())
                    finally:
                        if child.poll() is None: child.kill(); child.communicate()
            finally:
                common.release_operation_lock(descriptor)

    def test_startup_lock_works_without_shell_flock(self):
        source = (ROOT / 'selfhost/chronicle').read_text()
        function = re.search(r'^lock_operation\(\) \{\n.*?^\}', source, re.M | re.S).group(0)
        with tempfile.TemporaryDirectory() as folder:
            state = Path(folder)
            script = state / 'operation.sh'
            script.write_text('''#!/usr/bin/env bash
set -eu
SCRIPT_PATH="$0"
STATE_ROOT="$1"
ops_python() { case "$1" in -c) python3 "$@" ;; *) python3 -m chronicle_ops "$@" ;; esac; }
die() { exit 1; }
flock() { exit 99; }
''' + function + '''
lock_operation
python3 -c 'from chronicle_ops.common import acquire_operation_lock; import sys; assert acquire_operation_lock(sys.argv[1]) is None' "$STATE_ROOT"
# The shell itself holds the lock after the helper exits: an unrelated process is refused.
env -u CHRONICLE_OPERATION_LOCK_FD python3 -c 'from chronicle_ops.common import acquire_operation_lock; import sys
try: acquire_operation_lock(sys.argv[1], blocking=False)
except BlockingIOError: sys.exit(0)
sys.exit(3)' "$STATE_ROOT" 9<&-
''')
            script.chmod(0o700)
            result = subprocess.run(['bash', str(script), folder], env=dict(os.environ, PYTHONPATH=str(ROOT / 'selfhost'),
                                    CHRONICLE_OPS_STATE=folder), capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_recovery_verification_and_completion_hold_the_same_lock(self):
        from chronicle_ops.__main__ import main
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, CHRONICLE_OPS_STATE=folder):
            def check(*args):
                self.assertIsNone(common.acquire_operation_lock(folder))
                result = subprocess.run([sys.executable, '-c',
                    'from chronicle_ops.common import acquire_operation_lock; import sys; acquire_operation_lock(sys.argv[1], blocking=False)', folder],
                    env={key: value for key, value in dict(os.environ, PYTHONPATH=str(ROOT / 'selfhost')).items() if key != common.LOCK_FD_ENV},
                    capture_output=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                return 0
            with patch('chronicle_ops.verify.verify', side_effect=check), \
                 patch('chronicle_ops.reconcile.complete_recovery', side_effect=check) as complete, \
                 patch('chronicle_ops.__main__.finish_operation'):
                self.assertEqual(main(['verify']), 0)
                complete.assert_called_once()
            self.assertNotIn(common.LOCK_FD_ENV, os.environ)

    def test_dashboard_trust_tracks_the_certificate_issuer_for_both_probes(self):
        with tempfile.TemporaryDirectory() as folder:
            tls = Path(folder) / 'tls'; tls.mkdir()
            (tls / 'internal-ca.crt').write_text('fixture anchor')
            settings = {'DASHBOARD_BASE_URL': 'https://dashboard.example.org'}
            for verifies, expected in ((0, 'internal-ca.crt'), (1, 'internal-cert.pem')):
                with patch.object(common, 'run', return_value=SimpleNamespace(returncode=verifies)) as openssl, \
                     patch.object(verify, 'run', return_value=SimpleNamespace(returncode=0, stdout='204')) as curl, \
                     patch.object(verify, 'read_env', return_value=settings), \
                     patch.object(Path, 'is_file', return_value=True), \
                     patch.dict(os.environ, CHRONICLE_OPS_STATE=folder):
                    verify.curl(settings['DASHBOARD_BASE_URL'] + '/health')
                    self.assertIn(str(tls / expected), curl.call_args.args[0])
                    self.assertIn(str(tls / 'internal-cert.pem'), openssl.call_args.args[0])
            self.assertIn('dashboard_ca("/tls")', (ROOT / 'selfhost/monitoring/probe.sh').read_text())

    def test_monitoring_healthcheck_uses_its_mounted_certificate(self):
        import yaml
        grafana = yaml.safe_load((ROOT / 'selfhost/overlays/monitoring.yml').read_text())['services']['grafana']
        certificate = grafana['environment']['GF_SERVER_CERT_FILE']
        # The image's wget is BusyBox, which has no CA option; curl verifies against the mount.
        self.assertIn('curl -fsS -o /dev/null --cacert ' + certificate, grafana['healthcheck']['test'][1])
        self.assertTrue(any(mount.endswith(':' + certificate + ':ro') or
                            mount.endswith(':' + str(Path(certificate).parent) + ':ro') for mount in grafana['volumes']))
        # On a read-only root Grafana must keep its bundled datasources rather than replace them.
        self.assertTrue(grafana['read_only'])
        self.assertEqual(grafana['environment']['GF_PLUGINS_PREINSTALL_AUTO_UPDATE'], 'false')

    def test_smoke_volume_patch_caps_only_the_predecessor_and_fixture_uses_http(self):
        import hashlib
        import yaml
        source = (ROOT / 'tests/smoke/selfhost-release-smoke.sh').read_text()
        block = source[source.index('# Fresh installs keep the shipped volume'):source.index('\nbackup_image = ')]
        with tempfile.TemporaryDirectory() as folder:
            bundles = []
            for name, siblings in (('old', ''), ('new', '  postgres_tls:\n  backend_tls:\n')):
                bundle = Path(folder) / name / 'selfhost'; bundle.mkdir(parents=True); bundles.append(bundle)
                (bundle / 'docker-compose.yml').write_text('services: {}\nvolumes:\n' + siblings + '  postgres_data:\n')
                (bundle.parent / 'release-manifest.json').write_text('{"files":{}}')
            with patch.dict(os.environ, DISK_SMOKE_VOLUME_BYTES='1024'):
                exec(block, dict(old_bundle=bundles[0], new_bundle=bundles[1], os=os, json=json, hashlib=hashlib, candidate_supplied=False))
            old, new = (yaml.safe_load((bundle / 'docker-compose.yml').read_text())['volumes'] for bundle in bundles)
            self.assertEqual(old['postgres_data']['driver_opts']['type'], 'tmpfs')
            # The fresh install runs the candidate's shipped, uncapped volume.
            self.assertIsNone(new['postgres_data'])
            self.assertIsNone(new['postgres_tls'])
            fixture = source[source.index('name = f"chronicle-selfhost-'):source.index("\nPY\npython3 -m http.server")]
            with patch.dict(os.environ, RELEASE_VERSION='1.0.1', RELEASE_PORT='8080', RELEASE_FIXTURE_DIR=folder):
                exec(fixture, dict(os=os, json=json, Path=Path))
            for asset in json.loads((Path(folder) / 'latest.json').read_text())['assets']:
                self.assertTrue(asset['browser_download_url'].startswith('http://127.0.0.1:8080/'))

    def test_protected_docker_descendant_uses_actual_mount_without_pulling_an_image(self):
        protected = Path('/mounted docker/private')
        disk = SimpleNamespace(f_bavail=20, f_frsize=common.GIB, f_favail=common.MIN_FREE_INODES, f_files=50_000)
        def statvfs(path):
            if Path(path) == protected:
                raise PermissionError('protected descendant')
            return disk
        with patch.object(common, 'run', side_effect=[SimpleNamespace(stdout=str(protected)), SimpleNamespace(stdout=''), SimpleNamespace(stdout='')]) as run, \
             patch.object(common.os, 'statvfs', side_effect=statvfs) as measured, \
             patch.object(Path, 'read_text', return_value='1 0 8:0 / / rw\n2 1 8:1 / /mounted\\040docker rw\n'):
            rows = common.storage_report('/state', 'fixture')
        self.assertTrue(all(row[1] for row in rows))
        self.assertEqual(run.call_count, 3)
        self.assertEqual(measured.call_args.args[0], Path('/mounted docker'))

    def test_existing_database_bind_volume_is_checked_after_containers_are_removed(self):
        results = [SimpleNamespace(stdout='/docker'), SimpleNamespace(stdout=''), SimpleNamespace(stdout='fixture-db'),
                   SimpleNamespace(stdout=json.dumps([{'Mountpoint': '/docker/volumes/fixture-db/_data',
                                                       'Options': {'type': 'none', 'o': 'bind', 'device': '/database'}}]))]
        disk = SimpleNamespace(f_bavail=20, f_frsize=common.GIB, f_files=100000, f_favail=20000)
        with patch.object(common, 'run', side_effect=results), patch.object(common.os, 'statvfs', return_value=disk) as measured:
            rows = common.storage_report('/state', 'fixture')
        self.assertEqual(rows[-1][0], 'database-volume')
        self.assertEqual(measured.call_args.args[0], Path('/database'))

    def test_forward_acceptance_transfers_schedule_and_releases_checkpoint(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, clear=True):
            state = Path(folder); owner = state/'new'; owner.mkdir()
            marker = state/'.chronicle-upgrade.lock'; marker.mkdir()
            receipts.write_json(marker/reconcile.RECOVERY_FILE, {'owner':str(owner), 'phase':reconcile.RECOVERY_PHASE})
            os.environ.update(CHRONICLE_OPS_STATE=folder, CHRONICLE_OPS_PROJECT='fixture')
            with patch.object(Path, 'cwd', return_value=owner), patch('chronicle_ops.reconcile.preflight'), patch('chronicle_ops.reconcile.install') as install:
                reconcile.complete_recovery()
                install.assert_called_once_with(owner/'chronicle', state, 'fixture')
            self.assertFalse(marker.exists())
            self.assertNotIn(common.LOCK_FD_ENV, os.environ)

    def test_release_cleanup_retains_active_state_recovery_and_rollback_window(self):
        with tempfile.TemporaryDirectory() as folder:
            parent = Path(folder); bundles=[]
            for version in range(1,7):
                path=parent/f'chronicle-selfhost-1.0.{version}'; (path/'selfhost').mkdir(parents=True)
                (path/'release-manifest.json').write_text(json.dumps({'release_version':f'1.0.{version}',
                    'images':{'backend':f'fixture:{version}@sha256:'+'a'*64}}))
                path.with_name(path.name+'.tar.gz').touch(); bundles.append(path)
            state=bundles[0]/'selfhost'; marker=state/'.chronicle-upgrade.lock'; marker.mkdir()
            receipts.write_json(marker/reconcile.RECOVERY_FILE, {'owner':str(bundles[1]/'selfhost')})
            with patch.object(Path,'cwd',return_value=bundles[-1]/'selfhost'), patch('chronicle_ops.release.run', return_value=SimpleNamespace(stdout='[]')) as run, patch('sys.stdout',io.StringIO()):
                release.cleanup_releases(parent,state)
                self.assertTrue(all(path.exists() for path in bundles))
                self.assertTrue(all('rm' not in call.args[0] for call in run.call_args_list))
                release.cleanup_releases(parent,state,True)
            self.assertEqual([path.exists() for path in bundles], [True,True,False,True,True,True])
            self.assertFalse(bundles[2].with_name(bundles[2].name+'.tar.gz').exists())
            self.assertIn('--',run.call_args.args[0])
            # Automatic cleanup retains only the active and immediate rollback image owners,
            # even when private state keeps an older release directory on disk.
            with patch.object(Path, 'cwd', return_value=bundles[-1] / 'selfhost'), \
                 patch('chronicle_ops.release.run', return_value=SimpleNamespace(stdout='[]')) as automatic, patch('sys.stdout', io.StringIO()):
                release.cleanup_releases(parent, state, True, rollback_target=bundles[-2])
            removed = {call.args[0][-1] for call in automatic.call_args_list if call.args[0][:3] == ['docker', 'image', 'rm']}
            self.assertEqual(removed, {f'fixture:{version}@sha256:' + 'a' * 64 for version in (1, 2, 4)})
            self.assertTrue(bundles[-2].exists())


    def test_ipv6_host_sockets_and_backend_origin_use_native_shell_syntax(self):
        source=(ROOT/'selfhost/chronicle').read_text()
        start=source.index('host_listening() {'); end=source.index('\n}\n',start)+2
        shell=source[start:end]+'\nss() { printf "Header\\nLISTEN 0 0 [fd42::1]:8081 [::]:*\\n"; }; host_listening'
        result=subprocess.run(['bash','-c',shell], capture_output=True,text=True,check=True)
        self.assertEqual(result.stdout,'fd42::1:8081\n')
        source=(ROOT/'selfhost/backend-entrypoint.sh').read_text()
        start=source.index('case "$INTERNAL_BIND" in'); end=source.index('\nesac',start)+len('\nesac')
        for address in ('fd42::1','[fd42::1]','127.0.0.1'):
            result=subprocess.run(['sh','-c',source[start:end]+'\nprintf "%s" "$INTERNAL_BIND"'],
                                  env=dict(os.environ,INTERNAL_BIND=address),capture_output=True,text=True,check=True)
            self.assertEqual(result.stdout,'127.0.0.1' if address=='127.0.0.1' else '[fd42::1]')

    def test_cleanup_preserves_another_deployments_configuration_state_and_live_owner(self):
        for kind in ('configuration', 'backup', 'tls', 'live'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
                parent = Path(folder); state = parent / 'state'; state.mkdir()
                bundles = []
                for version in range(7):
                    path = parent / f'chronicle-selfhost-1.0.{version}'
                    (path / 'selfhost').mkdir(parents=True)
                    (path / 'release-manifest.json').write_text(json.dumps({'release_version': f'1.0.{version}',
                        'images': {'backend': f'fixture:{version}@sha256:' + 'a' * 64}}))
                    path.with_name(path.name + '.tar.gz').touch(); bundles.append(path)
                other = bundles[0] / 'selfhost'
                rows = []
                if kind == 'configuration':
                    (other / '.env').write_text('JWT_SECRET=synthetic-private-configuration\n')
                elif kind in ('backup', 'tls'):
                    directory = other / ('backups' if kind == 'backup' else 'tls'); directory.mkdir()
                    (directory / 'private-fixture').write_text('must survive')
                else:
                    rows = [{'Name': 'other-deployment', 'ConfigFiles': str(other / 'docker-compose.yml')}]
                with patch.object(Path, 'cwd', return_value=bundles[-1] / 'selfhost'), \
                     patch('chronicle_ops.release.run', return_value=SimpleNamespace(stdout=json.dumps(rows))), \
                     patch('sys.stdout', io.StringIO()):
                    release.cleanup_releases(parent, state, True)
                self.assertTrue(bundles[0].exists())
                self.assertTrue(bundles[0].with_name(bundles[0].name + '.tar.gz').exists())
                self.assertFalse(bundles[1].exists())

    def test_unset_pool_allowlist_admits_any_source(self):
        # A 2026.10.3 .env has no POOL_ALLOWED_IPS; a loopback default would 403 every phone.
        compose=(ROOT/'selfhost/docker-compose.yml').read_text()
        self.assertEqual(compose.count('POOL_ALLOWED_IPS: ${POOL_ALLOWED_IPS:-0.0.0.0/0 ::/0}'),
                         compose.count('      POOL_ALLOWED_IPS:'))
        self.assertIn('{$POOL_ALLOWED_IPS:0.0.0.0/0 ::/0}',(ROOT/'selfhost/caddy/snippets.caddy').read_text())
        self.assertIn('\nPOOL_ALLOWED_IPS=\n',(ROOT/'selfhost/.env.example').read_text())

    def test_backup_marker_requires_active_fresh_verified_dump(self):
        with tempfile.TemporaryDirectory() as folder:
            last = Path(folder) / 'last'; last.mkdir()
            path = last / 'custom-1.sql.gz'; path.write_bytes(gzip.compress(DUMP))
            dump.publish_backup(path, 'custom', {'database_bytes': 4096})
            self.assertEqual(dump.verified_backup(folder, 'custom')[0], path)
            with self.assertRaises(OSError): dump.verified_backup(folder, 'chronicle')
            with patch('chronicle_ops.dump.time.time', return_value=time.time() + dump.BACKUP_MAX_AGE_SECONDS + 1):
                with self.assertRaises(dump.DumpError): dump.verified_backup(folder, 'custom')
            path.write_bytes(b'failed dump')
            with self.assertRaises(dump.DumpError): dump.verified_backup(folder, 'custom')

    def test_failed_scratch_restore_never_publishes_or_accumulates_dumps(self):
        spec = importlib.util.spec_from_file_location('topology_selfcheck', ROOT / 'selfhost/backup-image/selfcheck.py')
        check = importlib.util.module_from_spec(spec); spec.loader.exec_module(check)
        with tempfile.TemporaryDirectory() as folder:
            last = Path(folder) / 'last'; last.mkdir()
            def snapshot(database, path, options):
                path.write_bytes(gzip.compress(DUMP)); return {'database_bytes': 4096}
            with patch.object(check, 'dump_snapshot', side_effect=snapshot), patch.object(check, 'drop_scratch'), patch('sys.stderr', io.StringIO()), patch('sys.stdout', io.StringIO()):
                for i in range(3):
                    with patch.object(check, 'check_dump', side_effect=RuntimeError('scratch failed')):
                        self.assertEqual(check.main(['dump', 'custom', str(last / f'custom-{i}.sql.gz')]), 1)
                    self.assertEqual(list(last.glob('*.sql.gz*')), [])
                    self.assertFalse(dump.backup_marker(folder, 'custom').exists())
                with patch.object(check, 'check_dump'):
                    self.assertEqual(check.main(['dump', 'custom', str(last / 'custom-good.sql.gz')]), 0)
                self.assertEqual(dump.verified_backup(folder, 'custom')[0].name, 'custom-good.sql.gz')

    def test_doctor_projects_scratch_retention_and_wal_independently_of_tde(self):
        with tempfile.TemporaryDirectory() as folder:
            data = {'database_bytes': 10000, 'wal_bytes': 5000, 'max_wal_bytes': 2000}
            result = SimpleNamespace(stdout='Filesystem blocks used available percent mount\ndisk 100 90 1 90% /db\n'+json.dumps(data))
            settings = {'POSTGRES_DB': 'custom', 'COMPOSE_FILE': 'docker-compose.yml:overlays/backups.yml', 'ENABLE_ENCRYPTION': 'false'}
            with patch('chronicle_ops.verify.compose', return_value=result), patch('chronicle_ops.verify.os.statvfs', return_value=SimpleNamespace(f_bavail=1, f_frsize=1024)):
                rows = verify.capacity_checks(settings, folder)
                self.assertEqual([(row[0], row[1]) for row in rows], [('database-disk', 'fail'), ('backup-reserve', 'fail'), ('backup-footprint', 'warn'), ('postgres-wal', 'warn')])
                settings['COMPOSE_FILE']='docker-compose.yml'
                self.assertEqual([row[0] for row in verify.capacity_checks(settings, folder)], ['database-disk', 'postgres-wal'])

    def test_metrics_require_every_target_and_fresh_samples(self):
        from datetime import datetime, timezone
        now = int(time.time())
        targets = [{'labels': {'job': job}, 'health': 'up', 'lastScrape': datetime.fromtimestamp(now, timezone.utc).isoformat()} for job in verify.MONITORING_JOBS]
        payload = {'data': {'activeTargets': targets}}
        self.assertTrue(verify.healthy_targets(payload, now))
        self.assertFalse(verify.healthy_targets({'data': {'activeTargets': targets[:-1]}}, now))
        self.assertFalse(verify.healthy_targets(payload, now + verify.METRICS_MAX_AGE_SECONDS + 1))
        targets[0]['health']='down'
        self.assertFalse(verify.healthy_targets(payload, now))

    def test_routine_receipts_are_bounded_and_incidents_retained(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, CHRONICLE_OPS_STATE=folder), patch.object(receipts, 'ROUTINE_RECEIPT_KEEP', 3):
            receipts.write_operation_receipt('up', 'failure', 'startup_failed')
            receipts.write_operation_receipt('upgrade', 'success')
            for _ in range(6): receipts.write_operation_receipt('up', 'success')
            files = list((Path(folder) / 'operator-receipts/operations').glob('*.json'))
            self.assertEqual(len(files), 5)
            self.assertEqual(sum(json.loads(path.read_text())['outcome'] == 'failure' for path in files), 1)

    def test_repeated_reconciliation_failures_are_bounded_per_operation(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder, \
             patch.dict(os.environ, CHRONICLE_OPS_STATE=folder), patch.object(receipts, 'ROUTINE_RECEIPT_KEEP', 3):
            receipts.write_operation_receipt('upgrade', 'failure', 'upgrade_failed')
            for _ in range(6):
                receipts.write_operation_receipt('up', 'failure', 'startup_failed')
                receipts.write_operation_receipt('doctor', 'failure', 'diagnosis_failed')
            files = list((Path(folder) / 'operator-receipts/operations').glob('*.json'))
            self.assertEqual(len(files), 7)
            self.assertEqual(sum(json.loads(path.read_text())['operation'] == 'up' for path in files), 3)

    def test_session_rejects_html_and_requires_cookie_follow_up(self):
        for response in ('<html>success</html>\n200', '{"authenticated": false}\n200'):
            with patch('chronicle_ops.verify.curl', return_value=(0, response)) as curl:
                self.assertFalse(verify.dashboard_session('https://management.example.org', 'synthetic')[0])
                self.assertEqual(curl.call_count, 1)
        with patch('chronicle_ops.verify.curl', side_effect=[(0, '{"authenticated":true,"csrfToken":"fixture"}\n200'), (0, '{"authenticated":false}\n200')]) as curl:
            self.assertFalse(verify.dashboard_session('https://management.example.org', 'synthetic')[0])
            self.assertIn('--cookie', curl.call_args.args)

    def test_session_token_must_match_the_csrf_cookie_session_set(self):
        def server(issued, returned):
            def fake(url, *args, **_):
                jar = args[args.index('--cookie-jar') + 1]
                token = 'login-token' if url.endswith('/dashboard-login') else issued
                Path(jar).write_text('# Netscape HTTP Cookie File\n'
                                     f'127.0.0.1\tFALSE\t/chronicle\tTRUE\t0\tol_csrf_token\t{token}\n')
                csrf = 'login-token' if url.endswith('/dashboard-login') else returned
                return 0, json.dumps({'authenticated': True, 'csrfToken': csrf}) + '\n200'
            return fake
        for issued, returned, expected in (('rotated', 'rotated', True), ('rotated', 'login-token', False), ('', '', False)):
            with patch('chronicle_ops.verify.curl', side_effect=server(issued, returned)):
                self.assertEqual(verify.dashboard_session('https://management.example.org', 'synthetic'), (expected, '200'))

    def test_monitoring_budget_includes_core_and_host_headroom(self):
        settings = release.read_env(ROOT / 'selfhost/.env.example')
        with self.assertRaises(ValueError): common.require_memory(settings, 4 * 1024 ** 2, True)
        self.assertLess(common.require_memory(settings, 10 * 1024 ** 2, True), 10 * common.GIB)

    def test_rollback_transfers_schedule_and_only_resumes_after_acceptance(self):
        from chronicle_ops.restore import rollback
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); old=root/'old'; current=root/'new'; state=root/'state'
            for path in (old,current,state): path.mkdir()
            settings=f"COMPOSE_PROJECT_NAME=fixture\nCHRONICLE_STATE_DIR='{state}'\nCOMPOSE_FILE=docker-compose.yml:overlays/mode-behind-proxy-internal.yml\n"
            for path in (old,current):
                (path/'.env').write_text(settings); (path/'.env').chmod(0o600); (path/'.env.example').write_text(settings)
            (old/'chronicle_ops').mkdir(); (old/'chronicle_ops/__main__.py').touch()
            marker=state/'.chronicle-upgrade.lock'; marker.mkdir()
            receipts.write_json(marker/reconcile.RECOVERY_FILE, {'owner':str(current),'phase':reconcile.RECOVERY_PHASE})
            events=[]
            def start(args, **kwargs):
                events.append(args[-1])
                self.assertTrue((state/reconcile.STOP_MARKER).exists())
                return SimpleNamespace(returncode=0)
            with patch.object(Path,'cwd',return_value=current), patch('chronicle_ops.restore.Restore.execute',return_value=0), \
                 patch('chronicle_ops.restore.compose'), patch('chronicle_ops.restore.return_monitoring_volumes'), patch('chronicle_ops.common.run',side_effect=start), \
                 patch('chronicle_ops.reconcile.install') as install, patch.dict(os.environ, clear=True):
                self.assertEqual(rollback(old,'/backups/reviewed.sql.gz','a'*64,True),0)
                install.assert_called_once_with(old/'chronicle',state,'fixture',update_only=True)
            self.assertEqual(events,['up','verify'])
            self.assertFalse((current / '.env').exists())
            archives = list((state / receipts.OPERATOR_RECEIPTS_DIR).glob('.env.rollback-*'))
            self.assertEqual(len(archives), 1)
            self.assertEqual(archives[0].stat().st_mode & 0o777, 0o600)
            self.assertEqual(release.read_env(archives[0])['COMPOSE_PROJECT_NAME'], 'fixture')
            self.assertFalse((state/reconcile.STOP_MARKER).exists())
            self.assertFalse(marker.exists())

    def test_rollback_preserves_rotated_credentials_and_previous_image_pins(self):
        from chronicle_ops.restore import rollback
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder); old = root / 'old'; current = root / 'new'; state = root / 'state'
            for path in (old, current, state): path.mkdir()
            credentials = {'POSTGRES_PASSWORD', 'JWT_SECRET', 'DASHBOARD_PASSWORD_HASH',
                           'CHRONICLE_INTERNAL_WEB_SECRET', 'METRICS_PASSWORD', 'GRAFANA_ADMIN_PASSWORD',
                           'MOBILE_SIGNING_SECRET', 'MOBILE_SIGNING_SECRET_PREVIOUS', 'MOBILE_SIGNING_ENABLED',
                           'CHRONICLE_REVIEWER_ACCESS_SECRET', 'CHRONICLE_REVIEWER_ACCESS_ENABLED'}
            settings = f"COMPOSE_PROJECT_NAME=fixture\nCHRONICLE_STATE_DIR='{state}'\nCOMPOSE_FILE=docker-compose.yml:overlays/mode-behind-proxy-internal.yml\n"
            for path, version in ((old, 'previous'), (current, 'current')):
                text = settings + f'BACKEND_IMAGE={version}-image\nRELEASE_VERSION={version}\n'
                text += ''.join(f"{key}='{version}-{key}'\n" for key in sorted(credentials))
                (path / '.env').write_text(text); (path / '.env').chmod(0o600); (path / '.env.example').write_text(text)
            (old / 'chronicle_ops').mkdir(); (old / 'chronicle_ops/__main__.py').touch()
            with patch.object(Path, 'cwd', return_value=current), \
                 patch('chronicle_ops.restore.Restore.execute', return_value=0), \
                 patch('chronicle_ops.restore.compose'), patch('chronicle_ops.restore.return_monitoring_volumes'), patch('chronicle_ops.common.run', return_value=SimpleNamespace(returncode=0)), \
                 patch('chronicle_ops.release.compose_projects', return_value=[{'Name': 'fixture', 'ConfigFiles': str(current / 'docker-compose.yml')}]), \
                 patch('chronicle_ops.reconcile.install'), patch.dict(os.environ, clear=True):
                self.assertEqual(rollback(old, '/backups/reviewed.sql.gz', 'a' * 64, True), 0)
            actual = release.read_env(old / '.env')
            for key in credentials:
                self.assertEqual(release.value(actual, key), f'current-{key}')
            self.assertEqual(release.value(actual, 'BACKEND_IMAGE'), 'previous-image')
            self.assertEqual(release.value(actual, 'RELEASE_VERSION'), 'previous')

    def test_superseded_rollback_cannot_restore_retired_credentials_or_pause_active_release(self):
        from chronicle_ops.restore import rollback
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder); state = root / 'state'; state.mkdir()
            old, superseded, active = (root / name for name in ('A', 'B', 'C'))
            for path in (old, superseded, active):
                path.mkdir()
                (path / '.env').write_text(f"COMPOSE_PROJECT_NAME=fixture\nCHRONICLE_STATE_DIR='{state}'\nJWT_SECRET={path.name}-secret\n")
                (path / '.env').chmod(0o600)
            (state / 'reconcile.sh').write_text('cd ' + str(active) + '\n')
            snapshot = (old / '.env').read_text()
            for inventory in ([], [{'Name': 'fixture', 'ConfigFiles': str(active / 'docker-compose.yml')}]):
                with patch.object(Path, 'cwd', return_value=superseded), \
                     patch('chronicle_ops.release.compose_projects', return_value=inventory), \
                     patch('chronicle_ops.restore.Restore.execute') as restore, \
                     patch('chronicle_ops.reconcile.install') as install, \
                     self.assertRaisesRegex(ValueError, 'superseded|does not own'):
                    rollback(old, '/backups/reviewed.sql.gz', 'a' * 64, True)
                restore.assert_not_called(); install.assert_not_called()
                self.assertEqual((old / '.env').read_text(), snapshot)
                self.assertFalse((state / reconcile.STOP_MARKER).exists())
            with patch.object(Path, 'cwd', return_value=active), \
                 patch('chronicle_ops.release.compose_projects', return_value=[]), \
                 patch('chronicle_ops.restore.Restore', return_value=SimpleNamespace(execute=lambda: 1, preserve=False, held=False)):
                self.assertEqual(rollback(old, '/backups/reviewed.sql.gz', 'a' * 64, True), 1)
                self.assertTrue((active / '.env').exists())
                self.assertEqual(list((state / receipts.OPERATOR_RECEIPTS_DIR).glob('.env.rollback-*')), [])
            self.assertFalse((state / reconcile.STOP_MARKER).exists())

    def test_host_routes_force_safe_subnet_selection_without_docker_conflicts(self):
        spec=importlib.util.spec_from_file_location('topology_subnet',ROOT/'selfhost/network-subnet.py')
        subnet=importlib.util.module_from_spec(spec);spec.loader.exec_module(subnet)
        networks=[{'Name':'VPN','IPAM':{'Config':[{'Subnet':'172.28.0.0/16'},{'Subnet':'10.253.0.0/24'}]}}]
        with patch.object(subnet,'docker_networks',return_value=[]), patch.object(subnet,'host_networks',return_value=networks), patch('sys.stdout',io.StringIO()) as output:
            subnet.select('172.28.0.0/16','fixture')
            self.assertEqual(output.getvalue(),'10.253.1.0/24\n')

    def test_remote_tls_does_not_disable_trust_and_ipv6_authority_is_valid(self):
        with patch('chronicle_ops.verify.run', return_value=SimpleNamespace(returncode=0, stdout='204')) as run:
            verify.curl('https://public.example.org:8443/health')
            args = run.call_args.args[0]
            self.assertNotIn('-k', args); self.assertNotIn('--insecure', args)
        self.assertEqual(verify.authority('fd42::1', '8443'), '[fd42::1]:8443')

    def test_persisted_upload_receipts_reject_missing_and_duplicate_rows(self):
        records={'study': '00000000-0000-0000-0000-000000000001', 'participant': 'smoke-fixture', 'tables': list(client.TABLES.values())}
        client.assert_persisted(records, lambda sql: '1')
        for count in ('0', '2'):
            with self.assertRaises(RuntimeError): client.assert_persisted(records, lambda sql: count)

    def test_paced_upload_preserves_content_length_and_json(self):
        captured = {}
        def open_request(request, timeout):
            captured['length'] = request.get_header('Content-length')
            captured['payload'] = b''.join(request.data)
            response = io.BytesIO(b'1'); response.status = 200
            response.headers = {'Content-Type': 'application/json'}
            return response
        body = [{'sample': 1}]
        with patch.object(client, 'TRANSFER_CHUNK_BYTES', 3), patch.object(client.time, 'sleep') as sleep:
            self.assertEqual(client.request(SimpleNamespace(open=open_request), 'https://fixture.example/upload', 'POST',
                                            body, padding_bytes=30, body_interval=0.1), 1)
            self.assertEqual(sleep.call_count, 10)
        self.assertEqual(captured['length'], '30')
        self.assertEqual(json.loads(captured['payload']), body)

    def test_transfer_contract_rejects_truncation_changed_content_and_accepted_idle_gap(self):
        recipe = {'upload': {'url': 'https://fixture.example/upload', 'headers': {}, 'body': []},
                  'download': {'url': 'https://fixture.example/export', 'headers': {}}}
        def response(payload):
            result = io.BytesIO(payload); result.status = 200
            return result
        for second, succeeds in ((b'abcdef', True), (b'abcdez', False), (b'abcde', False)):
            opener = SimpleNamespace(open=lambda *args, **kwargs: next(downloads))
            downloads = iter((response(b'abcdef'), response(second)))
            with patch.object(client, 'LARGE_EXPORT_BYTES', 6), patch.object(client, 'TRANSFER_CHUNK_BYTES', 2), \
                 patch.object(client, 'client', return_value=opener), patch.object(client, 'request', return_value=1), \
                 patch.object(client.time, 'sleep'):
                if succeeds:
                    client.transport_replay(recipe, None)
                else:
                    with self.assertRaises(RuntimeError): client.transport_replay(recipe, None)
        with patch.object(client, 'request', return_value=1):
            with self.assertRaisesRegex(RuntimeError, 'accepted a stalled upload'):
                client.transport_replay(recipe, None, idle_failure=True)

    def test_transparent_fixture_restores_host_filtering_after_route_cleanup_failure(self):
        source=(ROOT/'tests/deployment/selfhost-topology.sh').read_text()
        cleanup=source[source.index('cleanup() {'):source.index('\ntrap cleanup EXIT')]
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); (root/'selfhost').mkdir(); (root/'routes-installed').touch()
            for directory in ('all','pool'):
                (root/directory).mkdir(); (root/directory/'rp_filter').write_text('0')
            shell='''
RUN="$1"; STACK="$RUN/selfhost"; TOPOLOGY_POOL_BRIDGE=pool
route_priority=20000; route_table=120; rpf_all=1; rpf_pool=2
clients() { return 0; }; docker() { return 0; }
ip() { [[ "$*" != '-4 route flush table 120' ]]; }; export -f ip
host_routes() { bash -ceu "${1//\\/host-ipv4-conf/$RUN}"; }
'''+cleanup+'\ntrue; cleanup'
            result=subprocess.run(['bash','-c',shell,'fixture',folder],capture_output=True,text=True)
            self.assertEqual(result.returncode,1,result.stderr)
            self.assertEqual((root/'all/rp_filter').read_text(),'1')
            self.assertEqual((root/'pool/rp_filter').read_text(),'2')
            self.assertEqual((root/'result.txt').read_text(),'status=1\n')
