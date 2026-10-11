"""Audit regressions using synthetic settings and no live services."""

import fcntl
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'selfhost'))
from chronicle_ops import common, receipts, reconcile, release
from chronicle_ops.adopt import adopt
from chronicle_ops.restore import rollback


class AuditOpsTests(unittest.TestCase):
    def test_incident_listener_isolation_pauses_boot_and_periodic_reconciliation(self):
        from chronicle_ops.__main__ import main
        source = (ROOT / 'selfhost/chronicle').read_text()
        validate = re.search(r'^validate_command_arguments\(\) \{\n.*?^\}', source, re.M | re.S).group(0)
        result = subprocess.run(['bash', '-eu', '-c',
            'command_usage_error() { exit 1; };\n' + validate + '\nvalidate_command_arguments reconcile stop\n'],
            capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        runbook = (ROOT / 'selfhost/docs/INCIDENT-RESPONSE.md').read_text()
        self.assertLess(runbook.index('./chronicle reconcile stop'), runbook.index('docker compose stop web'))
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            state = Path(folder); active = state / 'active'; active.mkdir()
            (active / 'chronicle_ops').symlink_to(ROOT / 'selfhost/chronicle_ops', target_is_directory=True)
            calls = state / 'calls'
            launcher = active / 'chronicle'
            launcher.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >>"$CALLS"\n')
            launcher.chmod(0o755)
            with patch.dict(os.environ, {reconcile.ENABLED_ENV: 'true', 'CHRONICLE_OPS_STATE': str(state),
                                        'CHRONICLE_OPS_PROJECT': 'fixture', 'CALLS': str(calls)}, clear=False), \
                 patch('chronicle_ops.reconcile.platform.system', return_value='Linux'), \
                 patch('chronicle_ops.reconcile.shutil.which', return_value='/fixture/tool'), \
                 patch('chronicle_ops.reconcile.run', return_value=SimpleNamespace(returncode=0, stdout='', stderr='')) as cron:
                reconcile.install(launcher, state, 'fixture')
                self.assertIn('@reboot', cron.call_args.kwargs['input'])
                self.assertIn(f'*/{reconcile.INTERVAL_MINUTES}', cron.call_args.kwargs['input'])
                self.assertEqual(main(['reconcile', 'stop']), 0)
                result = subprocess.run(['bash', str(state / 'reconcile.sh')], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(calls.exists())

    def test_incident_collection_exports_both_database_audit_streams(self):
        runbook = (ROOT / 'selfhost/docs/INCIDENT-RESPONSE.md').read_text()
        export = runbook[runbook.index('for audit_table in '):runbook.index('# Operator receipts:')]
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            state = Path(folder)
            script = 'set -eu\ncase_dir="$CASE_DIR"\ndocker() { printf "%s\\n" "${@: -1}"; };\n' + export
            result = subprocess.run(['bash', '-c', script], env=dict(os.environ, CASE_DIR=str(state)),
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            for table in ('audit_logs', 'audit'):
                self.assertEqual((state / (table + '.csv')).read_text(), table + '\n')
            self.assertIn('ON_ERROR_STOP=1', export)

    def up_fixture(self, root):
        state = root / 'state'; state.mkdir(); (state / 'tls').mkdir()
        active = root / 'active'; retired = root / 'retired'
        settings = f"COMPOSE_PROJECT_NAME=fixture\nCHRONICLE_STATE_DIR='{state}'\nHTTP_BIND=127.0.0.1\nCOMPOSE_FILE=docker-compose.yml:overlays/mode-behind-proxy-internal.yml\n"
        for host in (active, retired):
            host.mkdir(); (host / '.env').write_text(settings); (host / '.env').chmod(0o600)
        (state / 'reconcile.sh').write_text('cd ' + str(active) + '\n')
        (state / reconcile.STOP_MARKER).touch()
        source = (ROOT / 'selfhost/chronicle').read_text()
        functions = '\n'.join(re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S).group(0)
                              for name in ('need_env', 'cmd_up'))
        script = '''set -eu
BLD= GRN= RST= PROJECT=fixture
STATE_ROOT="$PWD"
die() { echo "$*" >&2; exit 1; }
stat_mode() { stat -c '%a' "$1"; }
validate_legacy_mobile_values() { :; }
derive_mode() { :; }
for name in begin_operation assert_no_incomplete_mutation ensure_images preflight operation_succeeded; do
  eval "$name() { :; }"
done
lock_operation() { [[ -z "${LOCKED_SETTINGS:-}" ]] || cp "$LOCKED_SETTINGS" .env; }
ops_python() {
  export COMPOSE_FILE="${COMPOSE_FILE:-}" HTTP_BIND="${HTTP_BIND:-}"
  case "$1" in
    -c) PYTHONPATH="$OPS_PACKAGE" python3 "$@" ;;
    owner-check) PYTHONPATH="$OPS_PACKAGE" python3 - "$STATE_ROOT" "$PROJECT" <<'OWNER'
from pathlib import Path
import sys
from unittest.mock import patch
from chronicle_ops.release import require_current_owner
with patch('chronicle_ops.release.compose_projects', return_value=[]):
    require_current_owner(Path.cwd(), sys.argv[1], sys.argv[2])
OWNER
      ;;
    reconcile) [[ "$2" != stopped ]] || return 1
      [[ "$2" != resume ]] || rm -f "$STATE_ROOT/.chronicle-stopped" ;;
  esac
}
dc() {
  printf '%s %s %s\\n' "$HTTP_BIND" "$COMPOSE_FILE" "$*" >>"$CALLS"
  [[ "$*" != 'config --services' ]] || printf 'postgres\\nbackend\\nweb\\n'
}
''' + functions + '\ncmd_up up\n'
        return state, active, retired, settings, script

    def test_up_rejects_superseded_bundle_after_down_and_accepts_active_owner(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            state, active, retired, _, script = self.up_fixture(root)
            calls = root / 'calls'
            environment = dict(os.environ, OPS_PACKAGE=str(ROOT / 'selfhost'), CALLS=str(calls),
                               CHRONICLE_RECONCILE_ENABLED='true', CHRONICLE_RECONCILE_RUN='false')
            result = subprocess.run(['bash', '-c', script], cwd=retired, env=environment,
                                    capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('superseded', result.stderr)
            self.assertFalse(calls.exists())
            self.assertTrue((state / reconcile.STOP_MARKER).exists())
            result = subprocess.run(['bash', '-c', script], cwd=active, env=environment,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('--progress quiet up', calls.read_text())
            self.assertFalse((state / reconcile.STOP_MARKER).exists())

    def test_up_reloads_locked_settings_and_rejects_changed_lock_identity(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            _, active, _, settings, script = self.up_fixture(root)
            saved = root / 'locked-settings'; calls = root / 'calls'
            for changes, succeeds in (({'HTTP_BIND': '10.0.0.5', 'HTTP_PORT': '8085', 'COMPOSE_FILE': 'docker-compose.yml:overlays/mode-own-tls-internal.yml'}, True),
                                      ({'COMPOSE_PROJECT_NAME': 'other'}, False),
                                      ({'CHRONICLE_STATE_DIR': str(root)}, False)):
                (active / '.env').write_text(settings)
                latest = release.read_env(active / '.env')
                latest.update(changes)
                saved.write_text(''.join(f'{key}={raw}\n' for key, raw in latest.items()))
                calls.unlink(missing_ok=True)
                environment = dict(os.environ, OPS_PACKAGE=str(ROOT / 'selfhost'), CALLS=str(calls),
                                   LOCKED_SETTINGS=str(saved), CHRONICLE_RECONCILE_ENABLED='false')
                result = subprocess.run(['bash', '-c', script], cwd=active, env=environment,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                if succeeds:
                    self.assertIn('10.0.0.5 docker-compose.yml:overlays/mode-own-tls-internal.yml', calls.read_text())
                else:
                    self.assertFalse(calls.exists())

    def test_readable_operation_lock_survives_prestart_failure_and_inheritance(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            descriptor = common.acquire_operation_lock(folder)
            try:
                path = Path(folder) / common.OPERATION_LOCK
                self.assertTrue(path.stat().st_mode & 0o004)
                path.chmod(0o600)
                self.assertIsNone(common.acquire_operation_lock(folder))
                self.assertTrue(path.stat().st_mode & 0o004)
            finally:
                common.release_operation_lock(descriptor)

    def test_managed_update_check_moves_to_active_bundle_and_reports_failures(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder); tools = root / 'bin'; tools.mkdir()
            (root / 'release-manifest.json').write_text('{}')
            logger = tools / 'logger'
            logger.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >>"$LOGGER_CALLS"\n')
            logger.chmod(0o755)
            old = root / 'old'; active = root / 'active'
            for host in (old, active):
                host.mkdir()
                operator = host / 'chronicle'
                operator.write_text('#!/usr/bin/env bash\n[[ "$*" == "update --check" ]]\nprintf "%s\\n" "$PWD"\nexit "$CHECK_STATUS"\n')
                operator.chmod(0o755)
            with patch.dict(os.environ, {reconcile.ENABLED_ENV: 'true', 'PATH': str(tools) + ':' + os.environ['PATH']}), \
                 patch('chronicle_ops.reconcile.platform.system', return_value='Linux'), \
                 patch('chronicle_ops.reconcile.shutil.which', return_value='/fixture/tool'), \
                 patch('chronicle_ops.reconcile.run', return_value=SimpleNamespace(returncode=0, stdout='', stderr='')) as cron:
                reconcile.install(old / 'chronicle', root, 'fixture')
                reconcile.install(active / 'chronicle', root, 'fixture', update_only=True)
            self.assertIn('--check-updates', cron.call_args.kwargs['input'])
            for code, message in ((0, ''), (release.UPDATE_AVAILABLE_EXIT, 'update available'), (1, 'Update check failed')):
                log = root / 'logger-calls'; log.unlink(missing_ok=True)
                result = subprocess.run(['bash', str(root / 'reconcile.sh'), '--check-updates'],
                    env=dict(os.environ, CHECK_STATUS=str(code), LOGGER_CALLS=str(log)), capture_output=True, timeout=10)
                self.assertEqual(result.returncode, int(code == 1), result.stderr)
                details = root / reconcile.UPDATE_LOG
                self.assertEqual(details.read_text().strip(), str(active))
                self.assertEqual(details.stat().st_mode & 0o777, 0o600)
                if message:
                    self.assertIn(message, log.read_text())
                else:
                    self.assertFalse(log.exists())

    def test_legacy_rollback_passes_predecessor_permission_scan_and_uninstalls_cron(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder); old = root / 'old'; current = root / 'new'
            for host in (old, current):
                host.mkdir(mode=0o755)
                settings = f"COMPOSE_PROJECT_NAME=fixture\nCHRONICLE_STATE_DIR='{old}'\nCOMPOSE_FILE=docker-compose.yml:overlays/mode-behind-proxy-internal.yml\n"
                (host / '.env').write_text(settings); (host / '.env').chmod(0o600)
                (host / '.env.example').write_text(settings); (host / '.env.example').chmod(0o644)
            marker = old / '.chronicle-upgrade.lock'; marker.mkdir(mode=0o700)
            receipts.write_json(marker / reconcile.RECOVERY_FILE, {'owner': str(current), 'phase': reconcile.RECOVERY_PHASE})
            receipts.write_text(old / 'reconcile.sh', 'cd ' + str(current) + '\n')
            for name in ('reconcile.log', reconcile.UPDATE_LOG):
                receipts.write_text(old / name, 'private synthetic log\n')
            operator = old / 'chronicle'
            operator.write_text(r'''#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
if [[ "$1" == up ]]; then
  unreadable=$(find . \( -path ./backups -o -path ./operator-receipts -o -path ./upgrade-receipts -o -path ./tls -o -name '.env*' -o -name .git \) -prune -o \
    \( \( -type d ! -perm -0005 \) -o \( -type f ! -perm -0004 \) \) -print)
  [[ -z "$unreadable" ]] || { echo "$unreadable" >&2; exit 1; }
fi
''')
            operator.chmod(0o755)
            cron = '0 1 * * * unrelated\n@reboot old # chronicle-reconcile:fixture\n'
            with patch.object(Path, 'cwd', return_value=current), \
                 patch('chronicle_ops.restore.Restore.execute', return_value=0), \
                 patch('chronicle_ops.restore.compose'), patch('chronicle_ops.restore.return_monitoring_volumes'), \
                 patch('chronicle_ops.common.run', side_effect=lambda args, **kw: subprocess.run(args, **kw)), \
                 patch('chronicle_ops.reconcile.shutil.which', return_value='/fixture/crontab'), \
                 patch('chronicle_ops.reconcile.run', return_value=SimpleNamespace(returncode=0, stdout=cron, stderr='')) as scheduler, \
                 patch.dict(os.environ, {reconcile.ENABLED_ENV: 'true'}, clear=True):
                self.assertEqual(rollback(old, '/backups/reviewed.sql.gz', 'a' * 64, True), 0)
            self.assertEqual(scheduler.call_args.kwargs['input'], '0 1 * * * unrelated\n')
            self.assertFalse((old / 'reconcile.sh').exists())
            self.assertFalse((old / reconcile.STOP_MARKER).exists())
            for name in ('reconcile.log', reconcile.UPDATE_LOG):
                self.assertEqual((old / 'operator-receipts' / name).stat().st_mode & 0o777, 0o600)

    def test_adopt_rejects_superseded_source_before_compose_or_recovery(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder); source = root / 'source'; new = root / 'bundle/selfhost'; active = root / 'active'
            for path in (source, new, active): path.mkdir(parents=True)
            for name in ('backups', 'tls'): (source / name).mkdir()
            (source / '.env').write_text('COMPOSE_PROJECT_NAME=fixture\nCHRONICLE_STATE_DIR=.\n')
            (source / '.env').chmod(0o600)
            (new / '.env.example').write_text(''.join(key + '=fixture/image@sha256:' + 'a' * 64 + '\n'
                for key in ('BACKEND_IMAGE', 'SELFHOST_FRONTEND_IMAGE', 'CADDY_IMAGE')))
            (new.parent / 'release-manifest.json').write_text('{}')
            (source / 'reconcile.sh').write_text('cd ' + str(active) + '\n')
            for inventory in ([], [{'Name': 'fixture', 'ConfigFiles': str(active / 'docker-compose.yml')}]):
                with patch.object(Path, 'cwd', return_value=new), \
                     patch('chronicle_ops.adopt.read_manifest', return_value=({}, ())), \
                     patch('chronicle_ops.release.compose_projects', return_value=inventory), \
                     patch('chronicle_ops.adopt.compose_release') as compose, \
                     patch('chronicle_ops.adopt.checked_run') as run, patch('sys.stderr', io.StringIO()), \
                     patch.dict(os.environ, clear=True):
                    self.assertEqual(adopt(source), 1)
                compose.assert_not_called(); run.assert_not_called()
                self.assertFalse((new / '.env').exists())

    def test_rotation_recovery_reads_commented_exported_saved_credentials(self):
        source = (ROOT / 'selfhost/rotate-secret.sh').read_text()
        functions = '\n'.join(re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S).group(0)
                              for name in ('env_value_from_file', 'env_differs_from_saved'))
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder); transaction = root / 'transaction'; transaction.mkdir()
            keys = ('POSTGRES_PASSWORD', 'GRAFANA_ADMIN_PASSWORD', 'JWT_SECRET')
            saved = ''.join(f"export {key}='synthetic-#-saved' # operator comment\n" for key in keys)
            (transaction / 'old.env').write_text(saved)
            (root / '.env').write_text(saved)
            script = 'set -eu\nfail() { exit 1; }\n' + functions + '''
for key in POSTGRES_PASSWORD GRAFANA_ADMIN_PASSWORD JWT_SECRET; do
  [[ "$(env_value_from_file "$ROTATION_DIR/old.env" "$key")" == 'synthetic-#-saved' ]]
done
! env_differs_from_saved JWT_SECRET
printf 'export JWT_SECRET=synthetic-new # changed\\n' >.env
env_differs_from_saved JWT_SECRET
'''
            result = subprocess.run(['bash', '-c', script], cwd=root,
                env=dict(os.environ, SCRIPT_DIR=str(ROOT / 'selfhost'), ROTATION_DIR=str(transaction)),
                capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, b'')

    def test_rotation_recovery_accepts_reused_pid_under_operation_lock(self):
        source = (ROOT / 'selfhost/rotate-secret.sh').read_text()
        function = re.search(r'^load_transaction\(\) \{\n.*?^\}', source, re.M | re.S).group(0)
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            state = Path(folder); rotation = state / 'rotation'; rotation.mkdir()
            (rotation / 'owner-pid').write_text(str(os.getpid()) + '\n')
            script = 'set -eu\nfail() { echo "$*" >&2; exit 1; }\n' + function + '''
load_transaction
[[ "$TRANSACTION_ACTIVE" == true && "$TRANSACTION_PREPARED" == false ]]
'''
            descriptor = common.acquire_operation_lock(state)
            try:
                result = subprocess.run(['bash', '-c', script], capture_output=True, timeout=10,
                    env=dict(os.environ, ROTATION_DIR=str(rotation), UPGRADE_LOCK_DIR=str(state / 'upgrade'),
                             RESTORE_LOCK_DIR=str(state / 'restore')), pass_fds=(descriptor,))
            finally:
                common.release_operation_lock(descriptor)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_pruning_expires_interrupted_fragments_and_preserves_locked_active_dump(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder); rotation = root / 'secret-rotation'; rotation.mkdir()
            stale = [root / 'pre-upgrade-stale.sql.gz.partial', rotation / 'stale.sql.gz.partial']
            active = rotation / 'active.sql.gz.partial'; fresh = root / 'pre-upgrade-fresh.sql.gz.partial'
            for path in (*stale, active, fresh): path.write_bytes(b'synthetic')
            expired = time.time() - 4 * 24 * 60 * 60
            for path in (*stale, active): os.utime(path, (expired, expired))
            with active.open('rb') as fragment:
                fcntl.flock(fragment, fcntl.LOCK_EX)
                subprocess.run(['bash', str(ROOT / 'selfhost/backup-prune-hook.sh'), 'post-backup'],
                    env=dict(os.environ, BACKUP_DIR=folder, PRE_OP_BACKUP_KEEP_DAYS='1'),
                    capture_output=True, check=True, timeout=10)
                self.assertTrue(active.exists())
            self.assertTrue(fresh.exists())
            self.assertFalse(any(path.exists() for path in stale))
            subprocess.run(['bash', str(ROOT / 'selfhost/backup-prune-hook.sh'), 'post-backup'],
                env=dict(os.environ, BACKUP_DIR=folder, PRE_OP_BACKUP_KEEP_DAYS='1'),
                capture_output=True, check=True, timeout=10)
            self.assertFalse(active.exists())

    def test_upgrade_and_tde_dump_writers_lock_fragments_until_compression_finishes(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            probe = root / 'probe.py'
            probe.write_text('''import fcntl
import os
from pathlib import Path
import sys
from test_restore import DUMP
path = Path(sys.argv[1]) if len(sys.argv) > 1 else next(
    (Path(os.environ['STATE_ROOT']) / 'backups/secret-rotation').glob('*.partial'))
with path.open('rb') as fragment:
    try:
        fcntl.flock(fragment, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        raise SystemExit('dump writer did not protect its active fragment')
sys.stdout.buffer.write(DUMP)
''')
            environment = dict(os.environ, PYTHONPATH=str(Path(__file__).parent), STATE_ROOT=folder, PROBE=str(probe))
            path = root / 'pre-upgrade-locked.sql.gz.partial'
            self.assertEqual(len(release.rollback_dump([sys.executable, str(probe), str(path)], path, env=environment)), 64)
            source = (ROOT / 'selfhost/rotate-secret.sh').read_text()
            function = re.search(r'^take_pre_rotation_backup\(\) \{\n.*?^\}', source, re.M | re.S).group(0)
            script = 'set -eu\nfail() { echo "$*" >&2; exit 1; }\ndc() { python3 "$PROBE"; }\n' + function + '\ntake_pre_rotation_backup\n'
            (root / 'backups').mkdir()
            result = subprocess.run(['bash', '-c', script], env=environment, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(list((root / 'backups/secret-rotation').glob('*.sql.gz'))), 1)
