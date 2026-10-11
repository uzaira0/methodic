"""Focused regressions for the operator batch; no live services required."""

import copy
import importlib.util
import io
import json
from math import prod
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "selfhost"))
from chronicle_ops.common import WRITABLE_ROOT_REASON_LABEL
from chronicle_ops.reconcile import ENABLED_ENV, install, STOP_MARKER
from chronicle_ops.verify import verify_backup_storage


class OpsBatchTests(unittest.TestCase):
    def setUp(self):
        disabled = patch.dict(os.environ, {ENABLED_ENV: "false"})
        disabled.start()
        self.addCleanup(disabled.stop)

    def test_rate_probe_requires_actual_throttling_and_race_probe_rejects_missing_routes(self):
        node = shutil.which('node')
        self.assertIsNotNone(node, 'Node is required for the installed JavaScript probe regression')
        prelude = r"""
const metrics = {}, checks = [], requests = [];
class Counter { constructor(name) { this.name=name; metrics[name]=0; } add(value) { metrics[this.name]+=value; } }
const check = (response, predicates) => { const result=Object.values(predicates).every(fn=>fn(response)); checks.push(result); return result; };
const __ENV = {AUTH_TOKEN:'synthetic', STUDY_ID:'synthetic-study', TEST_DEVICE_ID:'synthetic-device', MOBILE_SIGNING_SECRET:'synthetic'};
const http = Object.fromEntries(['post','get','del','patch'].map(method=>[method,(url)=> {
 requests.push(url); return {status:PROBE_STATUS,json:()=>({}),headers:{'X-Ratelimit-Limit':String(url).endsWith('/session')?10:100}};
}]));
"""
        for file, calls, status in (
            ('tests/load/k6-rate-limit-validation.js', 'defaultBurst(); authBurst();', 404),
            ('tests/load/k6-rate-limit-validation.js', 'defaultBurst(); authBurst();', 200),
            ('tests/security/k6-race-conditions.js', "for(let i=0;i<10;i++){enrollment({}); nonce({}); deletion({}); settings({});}", 404),
        ):
            source = (ROOT / file).read_text()
            source = re.sub(r'^import .*?;\n', '', source, flags=re.M).replace('export ', '')
            result = subprocess.run([node, '-e', prelude.replace('PROBE_STATUS', str(status)) + source + calls +
                '\nconsole.log(JSON.stringify({metrics,checks,thresholds:options.thresholds}));'],
                check=True, capture_output=True, text=True)
            evidence = json.loads(result.stdout)
            self.assertIn(False, evidence['checks'])
            self.assertTrue(all(count == 0 for count in evidence['metrics'].values()))
            self.assertEqual(evidence['thresholds']['checks'], ['rate==1'])
        mirror = (ROOT / 'tests/load/k6-race-conditions.js').read_text()
        self.assertIn("from '../security/k6-race-conditions.js'", mirror)

    def test_expiry_probe_requires_identical_signed_claims_and_rejects_missing_inputs_and_throttling(self):
        import base64
        source = (ROOT / 'tests/security/session-management-tests.sh').read_text()
        signer = re.search(r'^make_jwt\(\) \{\n.*?^\}', source, re.M | re.S).group(0)
        probe = source[source.index('header "Test 1: Expired JWT Rejection"'):source.index('header "Test 2: JWT After Secret Rotation"')]
        claims = base64.urlsafe_b64encode(json.dumps({'sub': 'fixture-user', 'custom': 'preserved'}).encode()).decode().rstrip('=')
        status_stub = r"""
header() { :; }; pass() { :; }; fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); }
http_status() {
  [[ "$1" == GET && "$2" == "$BASE_URL/chronicle/v3/study" ]]
  TOKEN="${4#Authorization: Bearer }" python3 - <<'PY_TOKEN'
import base64, hashlib, hmac, json, os, time
header, payload, signature = os.environ['TOKEN'].split('.')
expected = base64.urlsafe_b64encode(hmac.new(os.environ['JWT_SECRET'].encode(), (header+'.'+payload).encode(), hashlib.sha256).digest()).decode().rstrip('=')
assert hmac.compare_digest(signature, expected)
claims = json.loads(base64.urlsafe_b64decode(payload+'='*(-len(payload)%4)))
assert claims['sub'] == 'fixture-user' and claims['custom'] == 'preserved'
assert claims['iat'] < time.time()
print(os.environ['VALID_STATUS'] if claims['exp'] > time.time() else os.environ['EXPIRED_STATUS'])
PY_TOKEN
}
"""
        script = 'set -eu\nFAIL_COUNT=0\n' + status_stub + signer + '\n' + probe + '\n[[ "$FAIL_COUNT" == 0 ]]'
        for valid, expired, secret, succeeds in ((200, 401, 'synthetic', True), (429, 401, 'synthetic', False),
                                                 (200, 429, 'synthetic', False), (200, 401, '', False)):
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=10,
                env=dict(os.environ, BASE_URL='https://fixture.invalid', AUTH_TOKEN='header.'+claims+'.signature',
                         JWT_SECRET=secret, VALID_STATUS=str(valid), EXPIRED_STATUS=str(expired)))
            self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)

    def test_study_isolation_requires_same_token_positive_control_on_real_participant_routes(self):
        source = (ROOT / 'tests/security/business-logic-tests.sh').read_text()
        helpers = '\n'.join(re.search(r'^'+name+r'\(\) \{\n.*?^\}', source, re.M | re.S).group(0)
                            for name in ('http_status', 'auth_http_status', 'assert_status'))
        probe = source[source.index('log "--- Test 1: Study Cross-Contamination ---"'):source.index('log "--- Test 2: Privilege Escalation ---"')]
        script = 'set -eu\nFAIL_COUNT=0\nlog() { :; }; pass() { :; }; fail() { FAIL_COUNT=$((FAIL_COUNT+1)); }\n' + helpers + '\n' + probe + '\n[[ "$FAIL_COUNT" == 0 ]]'
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            curl = Path(folder) / 'curl'
            curl.write_text('''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
assert 'Authorization: Bearer A-only' in args
url = args[-1]
route = url.removeprefix(os.environ['BASE_URL']+'/chronicle/v3/study/')
assert route in ('study-a/participants', 'study-b/participants'), route
print(os.environ['STATUS_A'] if route.startswith('study-a/') else os.environ['STATUS_B'], end='')
''')
            curl.chmod(0o755)
            for allowed, denied, succeeds in ((200, 403, True), (403, 403, False), (200, 404, False), (200, 429, False)):
                result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=10,
                    env=dict(os.environ, PATH=folder+os.pathsep+os.environ['PATH'], BASE_URL='https://fixture.invalid',
                             AUTH_TOKEN='A-only', STUDY_A='study-a', STUDY_B='study-b', STATUS_A=str(allowed), STATUS_B=str(denied)))
                self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)

    def test_permission_scan_and_repair_preserve_private_runtime_state(self):
        source = (ROOT / 'selfhost/chronicle').read_text()
        start = source.index('  local -a keep_private=')
        block = source[start:source.index('\n\n  # Signed mobile', start)]
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder); root.chmod(0o755)
            private_files = []
            for name in ('.chronicle-secret-rotation', 'upgrade-receipts'):
                private = root / name; private.mkdir(mode=0o700)
                saved = private / 'old.env'; saved.write_text('synthetic-secret'); saved.chmod(0o600)
                private_files.append(saved)
            lock = root / '.reconcile.lock'; lock.touch(mode=0o600)
            for name in ('.chronicle-stopped', 'reconcile.sh', 'reconcile.log'):
                path = root / name; path.touch(mode=0o600)
            shipped = root / 'entrypoint.sh'; shipped.write_text('# fixture'); shipped.chmod(0o644)
            script = 'bad() { printf "%s" "$permission_repair"; }; ok() { :; }; check_permissions() {\n' + block + '\n}; check_permissions'
            result = subprocess.run(['bash', '-eu', '-c', script], cwd=root, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '')
            shipped.chmod(0o600)
            result = subprocess.run(['bash', '-eu', '-c', script], cwd=root, capture_output=True, text=True, check=True, timeout=10)
            self.assertTrue(result.stdout.startswith('find '))
            subprocess.run(['bash', '-eu', '-c', result.stdout], cwd=root, check=True, timeout=10)
            self.assertEqual(shipped.stat().st_mode & 0o777, 0o644)
            for saved in private_files:
                self.assertEqual(saved.parent.stat().st_mode & 0o777, 0o700)
                self.assertEqual(saved.stat().st_mode & 0o777, 0o600)
            self.assertEqual(lock.stat().st_mode & 0o777, 0o600)

    def test_uninstall_removes_only_its_schedule_and_keeps_reconciliation_paused(self):
        from chronicle_ops.reconcile import uninstall
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            state = Path(folder); (state / 'reconcile.sh').write_text('old launcher')
            current = '0 1 * * * other-job\n@reboot old # chronicle-reconcile:fixture\n@reboot other # chronicle-reconcile:other\n'
            with patch('chronicle_ops.reconcile.shutil.which', return_value='/fixture/crontab'), \
                 patch('chronicle_ops.reconcile.run', return_value=SimpleNamespace(returncode=0, stdout=current, stderr='')) as run:
                uninstall(state, 'fixture')
            self.assertTrue((state / STOP_MARKER).exists())
            self.assertFalse((state / 'reconcile.sh').exists())
            self.assertEqual(run.call_args.kwargs['input'], '0 1 * * * other-job\n@reboot other # chronicle-reconcile:other\n')

    def test_reconciliation_shell_override_wins_over_saved_setting(self):
        source = (ROOT / 'selfhost/chronicle').read_text()
        function = re.search(r'^need_env\(\) \{\n.*?^\}', source, re.M | re.S).group(0)
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            path = Path(folder) / '.env'
            script = '''set -eu
die() { exit 1; }
stat_mode() { echo 600; }
ops_python() { :; }
validate_legacy_mobile_values() { :; }
derive_mode() { :; }
''' + function + '\nneed_env\nprintf "%s" "$CHRONICLE_RECONCILE_ENABLED"\n'
            for override, saved, expected in ((None, 'false', 'false'), ('false', 'true', 'false'), ('true', 'false', 'true')):
                path.write_text('CHRONICLE_RECONCILE_ENABLED=' + saved + '\n'); path.chmod(0o600)
                environment = dict(os.environ)
                environment.pop(ENABLED_ENV, None)
                if override is not None: environment[ENABLED_ENV] = override
                result = subprocess.run(['bash', '-c', script], cwd=folder, env=environment,
                                        capture_output=True, text=True, check=True, timeout=10)
                self.assertEqual(result.stdout, expected)

    def test_behind_proxy_loopback_trust_warns_without_blocking_snat_startup(self):
        source = (ROOT / 'selfhost/guard-config.sh').read_text()
        start = source.index('if [[ "$TLS_MODE" == behind-proxy ]] && loopback_networks')
        block = source[start:source.index('\nfi', start) + len('\nfi')]
        for cidrs in ('127.0.0.1/32 ::1/128', '172.28.0.1/32', '10.1.2.3/32'):
            script = 'source "$1"; bad() { exit 1; }; warn() { printf "%s" "$*"; }; ' + block
            result = subprocess.run(['bash', '-c', script, 'fixture', str(ROOT / 'selfhost/network-policy.sh')],
                env=dict(os.environ, TLS_MODE='behind-proxy', CADDY_TRUSTED_PROXIES=cidrs), capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(b'SNAT without XFF' in result.stdout, cidrs.startswith('127.'))

    def test_remote_f5_setup_defaults_accept_snat_without_adding_a_loopback_pool_acl(self):
        source = (ROOT / 'selfhost/chronicle').read_text()
        start = source.index('      # Host-loopback traffic reaches Caddy')
        block = source[start:source.index('\n    fi\n    local lb_body', start)]
        script = '''set -eu
source "$1"
die() { echo "$*" >&2; exit 1; }
http_bind=10.0.0.5
trusted_proxies_default=172.28.0.1/32
trusted_proxies="$trusted_proxies_default"
pool_sources= pool_port=8080
unset CADDY_TRUSTED_PROXIES
''' + block + '\nprintf "trust=%s\\npool=%s\\n" "$trusted_proxies" "$pool_sources"\n'
        result = subprocess.run(['bash', '-c', script, 'fixture', str(ROOT / 'selfhost/network-policy.sh')],
            input='\n\n\n', capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('trust=127.0.0.1/32\npool=\n', result.stdout)

    def test_setup_dashboard_default_tracks_the_selected_docker_gateway(self):
        source = (ROOT / 'selfhost/chronicle').read_text()
        start = source.index('  source ./network-policy.sh\n  local initial_subnet')
        initial = source[start:source.index('  [[ -n "$management_url"', start)]
        start = source.index('  gateway=$(ops_python', source.index('  local default_subnet subnet'))
        final = source[start:source.index('\n\n', start)]
        script = '''set -eu
ops_python() { PYTHONPATH="$PWD" python3 "$@"; }
die() { exit 1; }
setup_defaults() {
  domain=example.test
  internal_bind=127.0.0.1
''' + initial + '''
  subnet=10.253.1.0/24
  pool_sources="$trusted_proxies_default"
''' + final + '''
  printf '%s\\n' "$researcher_sources" "$trusted_proxies" "$pool_sources"
}
setup_defaults
'''
        environment = dict(os.environ)
        for key in ('DASHBOARD_ALLOWED_IPS', 'CADDY_TRUSTED_PROXIES'): environment.pop(key, None)
        result = subprocess.run(['bash', '-c', script], cwd=ROOT / 'selfhost', env=environment,
                                capture_output=True, text=True, check=True, timeout=10)
        self.assertEqual(result.stdout.splitlines(), ['10.253.1.1/32 127.0.0.1/32 ::1/128', '10.253.1.1/32', '10.253.1.1/32'])

    def test_dashboard_rotation_verifies_tls_bypasses_proxies_and_retains_acl_denied_rotation(self):
        source = (ROOT / 'selfhost/rotate-secret.sh').read_text()
        functions = '\n'.join(re.search(r'^' + name + r'\(\).*?^\}', source, re.M | re.S).group(0)
                              for name in ('escape_curl_config_value', 'curl_basic_code', 'dashboard_login_code', 'rotate_dashboard'))
        password = 'synthetic-"password\\0123456789'
        for mode, bind, code, expected in (('mode-behind-proxy-internal', '127.0.0.1', '200', 0),
                                          ('mode-local-https', '127.0.0.1', '200', 0),
                                          ('mode-behind-proxy-internal', '10.0.0.5', '403', 0),
                                          ('mode-behind-proxy-internal', '127.0.0.1', '403', 1),
                                          ('mode-behind-proxy-internal', '10.0.0.5', '000', 60)):
            with self.subTest(bind=bind, code=code), tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
                root = Path(folder)
                (root / '.env').write_text(f'INTERNAL_BIND={bind}\nDASHBOARD_BASE_URL=https://management.example.test\n')
                script = '''set -Eeuo pipefail
ROTATION_ACTION=rotate
COMPOSE_FILE="overlays/$ROTATION_MODE.yml"
DASHBOARD_PASSWORD_HASH=retired-hash
GRAFANA_URL=
NEW_SECRET= OLD_SECRET= RECEIPT_DETAIL=
service_running() { :; }
configure_apply() { :; }
begin_transaction() { :; }
env_update() { CURRENT_HASH="$2"; }
write_phase() { :; }
apply_configuration() { :; }
complete_transaction() { [[ "$CURRENT_HASH" == "$NEW_SECRET" ]]; printf 'committed %s\\n' "$RECEIPT_DETAIL"; }
fail() { echo "$*" >&2; exit 1; }
warn() { echo "$*" >&2; }
log() { echo "$*"; }
docker() { cat >/dev/null; printf '$2a$synthetic-hash'; }
curl() {
  local args=" $* "
  [[ "$args" != *' -k '* && "$args" != *' -sk '* && "$args" == *' --noproxy * '* && "$args" == *' --cacert '* ]] || exit 80
  [[ "${@: -1}" == https://management.example.test/* ]] || exit 81
  [[ "$args" != *' --config '* ]] || exit 82
  if [[ "${@: -1}" == */dashboard-login ]]; then
    python3 -c 'import json,sys; assert len(json.load(sys.stdin)["password"]) >= 16'
    printf 'session-probed\\n' >&2
  fi
  [[ "$CURL_CODE" != 000 ]] || return 60
  if [[ "${@: -1}" == */chronicle/api/web/study && "$CURL_CODE" == 200 ]]; then printf 401; else printf '%s' "$CURL_CODE"; fi
}
''' + functions + '\nrotate_dashboard\n'
                result = subprocess.run(['bash', '-c', script], cwd=root, input=password + '\n' + password + '\n',
                    env=dict(os.environ, SCRIPT_DIR=str(ROOT / 'selfhost'), STATE_ROOT=str(root), INTERNAL_BIND=bind,
                             CURL_CODE=code, ROTATION_MODE=mode, HTTPS_PROXY='http://untrusted-proxy.invalid:3128'),
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertNotIn(password, result.stdout + result.stderr)
                self.assertEqual('committed' in result.stdout, expected == 0)
                if code == '200': self.assertIn('session-probed', result.stderr)
                if bind == '10.0.0.5' and code == '403':
                    self.assertIn('dashboard_auth=operator_check_required', result.stdout)
                    self.assertNotIn('session-probed', result.stderr)

    def test_secret_rotation_updates_exported_assignment_and_rejects_duplicates(self):
        source = (ROOT / 'selfhost/rotate-secret.sh').read_text()
        function = source[source.index('env_update() {'):source.index('\nrestore_old_env() {')]
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            path = Path(folder) / '.env'
            script = 'set -eu; fail() { exit 1; };\n' + function + '\nenv_update JWT_SECRET synthetic-new-secret\n'
            for prefix in ('', 'export ', '  export\t'):
                path.write_text(prefix + "JWT_SECRET='synthetic-old-secret'\nOTHER=keep\n")
                result = subprocess.run(['bash', '-c', script], cwd=folder,
                    env=dict(os.environ, SCRIPT_DIR=str(ROOT / 'selfhost')), capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(path.read_text(), "JWT_SECRET='synthetic-new-secret'\nOTHER=keep\n")
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            duplicate = 'JWT_SECRET=first\nexport JWT_SECRET=second\n'
            path.write_text(duplicate)
            result = subprocess.run(['bash', '-c', script], cwd=folder,
                env=dict(os.environ, SCRIPT_DIR=str(ROOT / 'selfhost')), capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_text(), duplicate)

    def test_certificate_renewal_failure_retry_and_monitoring_removal(self):
        source = (ROOT / 'selfhost/chronicle').read_text()
        functions = '\n'.join(re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S).group(0)
                              for name in ('cmd_up', 'cmd_down'))
        script = '''set -eu
BLD= RST= GRN= COMPOSE_FILE=docker-compose.yml PROJECT=fixture
STATE_ROOT="$1"
for name in need_env lock_operation assert_no_incomplete_mutation begin_operation ensure_images preflight operation_succeeded; do
  eval "$name() { :; }"
done
die() { echo "$*" >&2; exit 1; }
find() { cat "$STATE_ROOT/tls/published"; }
ops_python() {
  case "$1" in
    -c) PYTHONPATH="$OPS_PACKAGE" python3 "$@" ;;
    *) [[ "$*" != 'reconcile stopped' ]] ;;
  esac
}
dc() {
  case "$*" in
    'run --rm --no-deps cert-init') printf renewed >"$STATE_ROOT/tls/published" ;;
    'config --services') [[ "$FAIL_DISCOVERY" == false ]] || return 1; printf 'postgres\\nbackend\\nweb\\ndb-init\\ndb-backup\\n' ;;
    '--progress '*) printf '%s\\n' "$*" ;;
    'down '*) printf '%s\\n' "$*" ;;
  esac
}
''' + functions + '\ncmd_up up\ncmd_down down\n'
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            state = Path(folder); (state / 'tls').mkdir()
            marker = state / 'tls/.applied-certificates'; marker.write_text('previous')
            for failure, force in (('true', True), ('false', True), ('false', False)):
                result = subprocess.run(['bash', '-c', script, 'fixture', str(state)], capture_output=True, text=True,
                    env=dict(os.environ, FAIL_DISCOVERY=failure, CHRONICLE_RECONCILE_RUN='true', OPS_PACKAGE=str(ROOT / 'selfhost')), timeout=10)
                self.assertEqual(result.returncode, int(failure == 'true'), result.stderr)
                if failure == 'true':
                    self.assertEqual(marker.read_text(), 'previous')
                else:
                    self.assertEqual('--force-recreate' in result.stdout, force)
                    self.assertEqual('--no-recreate' in result.stdout, not force)
                    self.assertIn('--remove-orphans', result.stdout)
                    self.assertIn('down --remove-orphans', result.stdout)
                    self.assertEqual(marker.read_text(), 'renewed')
                    self.assertEqual(marker.stat().st_mode & 0o777, 0o600)

    def test_caddy_uses_the_backend_body_limit(self):
        backend = (ROOT / "chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/SecurityHardeningConfig.kt").read_text()
        expression = re.search(r"MAX_REQUEST_SIZE_BYTES: Long = (.*)", backend).group(1)
        backend_limit = prod(int(factor.strip()) for factor in expression.split("*"))
        caddy = (ROOT / "selfhost/caddy/snippets.caddy").read_text()
        limit_mib = int(re.search(r"max_size\s+(\d+)MiB\b", caddy).group(1))
        self.assertEqual(limit_mib * 1024 ** 2, backend_limit)

    def test_abandoned_reviewed_restore_copy_obeys_backup_retention(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder)
            stale = root / '.reviewed-restore.stale.sql.gz'; stale.write_bytes(b'fixture')
            fresh = root / '.reviewed-restore.fresh.sql.gz'; fresh.write_bytes(b'fixture')
            from datetime import datetime, timedelta
            expired = (datetime.now() - timedelta(days=3)).timestamp()
            os.utime(stale, (expired, expired))
            subprocess.run(['bash', str(ROOT / 'selfhost/backup-prune-hook.sh'), 'post-backup'],
                env=dict(os.environ, BACKUP_DIR=folder, PRE_OP_BACKUP_KEEP_DAYS='1'),
                capture_output=True, check=True, timeout=10)
            self.assertFalse(stale.exists())
            self.assertTrue(fresh.exists())

    def test_backup_storage_encryption_and_reviewed_waiver(self):
        for devices, waiver, expected in (
            ([{"type": "crypt", "children": [{"type": "disk"}]}], "", 0),
            ([{"type": "disk"}], "", 1),
            ([{"type": "disk"}], "OPS-reviewed-2026-10-07", 0),
            ([{"type": "disk"}], "CHANGE_ME", 1),
            ([{"type": "raid", "children": [{"type": "crypt"}, {"type": "disk"}]}], "", 1),
        ):
            results = [SimpleNamespace(returncode=0, stdout="/dev/mapper/fixture"),
                       SimpleNamespace(returncode=0, stdout=json.dumps({"blockdevices": devices}))]
            with self.subTest(devices=devices, waiver=waiver), \
                 patch("chronicle_ops.verify.sys.platform", "linux"), \
                 patch("chronicle_ops.verify.run", side_effect=results) as runtime, patch("sys.stdout", io.StringIO()) as output:
                self.assertEqual(verify_backup_storage("/tmp", waiver), expected)
                self.assertIn("--tree", runtime.call_args_list[1].args[0])
                self.assertNotIn("FAIL", output.getvalue())
                if expected:
                    self.assertIn("warn", output.getvalue())
        with patch("chronicle_ops.verify.run", side_effect=OSError()), patch("sys.stdout", io.StringIO()):
            self.assertEqual(verify_backup_storage("/tmp"), 1)
        source = (ROOT / "selfhost/chronicle").read_text()
        for opening, closing, probe in (
            ('  if [[ "${ENABLE_BACKUPS:-true}" == true ]] && ! ops_python backup-storage; then',
             '\n  fi', 'bad() { exit 1; }; warn() { :; };'),
            ('    if ! ops_python backup-storage >/dev/null 2>&1; then',
             '\n    fi', 'doctor_add() { [[ "$2" == warn ]]; };'),
        ):
            start = source.index(opening)
            block = source[start:source.index(closing, start) + len(closing)]
            script = 'ops_python() { return 1; }; ' + probe + '\n' + block
            result = subprocess.run(["bash", "-eu", "-c", script], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_reconciliation_opt_out_and_scheduled_up_preserve_host_state(self):
        from chronicle_ops.__main__ import main
        from chronicle_ops.release import OWNER_FILE
        with tempfile.TemporaryDirectory() as folder, \
             patch("chronicle_ops.reconcile.run") as crontab, \
             patch.dict(os.environ, CHRONICLE_OPS_STATE=folder, CHRONICLE_OPS_PROJECT="fixture"):
            for update_only in (False, True):
                install(Path(folder) / "chronicle", folder, "fixture", update_only=update_only)
            for action in ("install", "stop", "resume"):
                self.assertEqual(main(["reconcile", action]), 0)
            crontab.assert_not_called()
            self.assertEqual([path.name for path in Path(folder).iterdir()], [OWNER_FILE])
        source = (ROOT / "selfhost/chronicle").read_text()
        functions = "\n".join(re.search(r"^" + name + r"\(\) \{\n.*?^\}", source, re.M | re.S).group(0)
                              for name in ("cmd_up", "validate_command_arguments"))
        script = functions + '''
BLD= RST= GRN=
STATE_ROOT=/tmp
find() { :; }
for name in need_env lock_operation assert_no_incomplete_mutation begin_operation ensure_images preflight; do
  eval "$name() { :; }"
done
need_env() { :; }
die() { echo "$*" >&2; exit 1; }
ops_python() {
  [[ "$*" != "reconcile resume" ]] || { rm -f "$STATE_ROOT/.chronicle-stopped"; echo 'unexpected resume' >&2; return 1; }
  [[ "$*" != "reconcile stopped" && "${CHRONICLE_RECONCILE_ENABLED:-true}" == false ]]
}
operation_succeeded() { printf 'reconcile=%s\\n' "$CHRONICLE_RECONCILE_ENABLED"; }
dc() {
  if [[ "$*" == 'config --services' ]]; then printf 'postgres\\nbackend\\nweb\\n';
  elif [[ "$1" == --progress ]]; then printf 'compose %s\\n' "$*"; fi
}
validate_command_arguments up --no-reconcile
cmd_up up --no-reconcile
'''
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            marker = Path(folder) / STOP_MARKER
            script = script.replace('STATE_ROOT=/tmp', 'STATE_ROOT="$FIXTURE_STATE"\nPROJECT=fixture')
            for scheduled in ("false", "true"):
                marker.touch()
                environment = dict(os.environ, CHRONICLE_RECONCILE_RUN=scheduled, FIXTURE_STATE=folder)
                environment[ENABLED_ENV] = "true"
                result = subprocess.run(["bash", "-eu", "-c", script], env=environment, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(b"reconcile=false", result.stdout)
                self.assertEqual(b"--no-recreate" in result.stdout, scheduled == "true")
                self.assertTrue(marker.exists())

    def test_reconciliation_preserves_cron_and_tracks_bundle(self):
        with tempfile.TemporaryDirectory() as folder:
            state = Path(folder)
            launcher = state / "bundle" / "chronicle"
            launcher.parent.mkdir()
            launcher.write_text("")
            (state / 'release-manifest.json').write_text('{}')
            old = "3 2 * * * other-job\n@reboot old # chronicle-reconcile:fixture\n"
            with patch("chronicle_ops.reconcile.platform.system", return_value="Linux"), \
                 patch.dict(os.environ, {ENABLED_ENV: "true"}), \
                 patch("chronicle_ops.reconcile.shutil.which", return_value="/fixture/tool"), \
                 patch("chronicle_ops.reconcile.run", return_value=SimpleNamespace(returncode=0, stdout=old, stderr="")) as run:
                install(launcher, state, "fixture")
                cron = run.call_args.kwargs["input"]
                self.assertIn("3 2 * * * other-job", cron)
                self.assertNotIn("@reboot old", cron)
                self.assertEqual(cron.count("# chronicle-reconcile:fixture"), 3)
                self.assertIn('--check-updates # chronicle-reconcile:fixture', cron)
                script = state / "reconcile.sh"
                self.assertEqual(script.stat().st_mode & 0o777, 0o700)
                self.assertIn("CHRONICLE_RECONCILE_RUN=true ./chronicle up || up_status=$?", script.read_text())
                self.assertIn("./chronicle doctor && ((up_status == 0))", script.read_text())
                self.assertIn(".chronicle-stopped", script.read_text())
                next_launcher = state / "new" / "chronicle"
                next_launcher.parent.mkdir()
                next_launcher.write_text("")
                install(next_launcher, state, "fixture", update_only=True)
                self.assertIn(str(next_launcher.parent), script.read_text())

    def test_scheduled_reconciliation_respects_manual_shutdown(self):
        with tempfile.TemporaryDirectory() as folder:
            state = Path(folder)
            launcher = state / "chronicle"
            shutil.copytree(ROOT / "selfhost/chronicle_ops", state / "chronicle_ops", ignore=shutil.ignore_patterns("__pycache__"))
            calls = state / "calls"
            launcher.write_text('#!/usr/bin/env bash\nprintf "%s %s\\n" "$1" "${CHRONICLE_RECONCILE_RUN:-false}" >>"$CALLS"\n[[ "$1" != up || "${UP_FAILURE_FIXTURE:-false}" != true ]]\n')
            launcher.chmod(0o700)
            tools = state / "bin"
            tools.mkdir()
            (tools / "logger").write_text("#!/usr/bin/env bash\nexit 0\n")
            (tools / "logger").chmod(0o700)
            with patch("chronicle_ops.reconcile.platform.system", return_value="Linux"), \
                 patch.dict(os.environ, {ENABLED_ENV: "true"}), \
                 patch("chronicle_ops.reconcile.shutil.which", return_value="/fixture/tool"), \
                 patch.dict(os.environ, PATH=str(tools) + ":" + os.environ["PATH"]), \
                 patch("chronicle_ops.reconcile.run", return_value=SimpleNamespace(returncode=0, stdout="", stderr="")):
                install(launcher, state, "fixture")
            script = state / "reconcile.sh"
            environment = dict(os.environ, CALLS=str(calls))
            subprocess.run(["bash", str(script)], env=environment, check=True, timeout=10)
            expected_calls = "up true\ndoctor false\n"
            self.assertEqual(calls.read_text(), expected_calls)
            calls.unlink()
            failure = subprocess.run(["bash", str(script)], env=dict(environment, UP_FAILURE_FIXTURE="true"), timeout=10)
            self.assertNotEqual(failure.returncode, 0)
            self.assertEqual(calls.read_text(), expected_calls)
            calls.unlink()
            (state / STOP_MARKER).touch()
            subprocess.run(["bash", str(script)], env=environment, check=True, timeout=10)
            self.assertFalse(calls.exists())
            source = script.read_text()
            self.assertLess(source.index("operation-lock"), source.index(STOP_MARKER))

    def test_monitoring_daemon_ownership_and_docker_api_boundary(self):
        import yaml
        services = yaml.safe_load((ROOT / "selfhost/overlays/monitoring.yml").read_text())["services"]
        for daemon in ("victoriametrics", "victorialogs", "fluent-bit", "grafana"):
            with self.subTest(daemon=daemon):
                self.assertNotEqual(services[daemon]["user"].split(":")[0], "0")
                self.assertTrue(services[daemon]["read_only"])
        for daemon in ("victoriametrics", "victorialogs", "fluent-bit"):
            self.assertIn("monitoring-config", services[daemon]["depends_on"])
        proxy = services["docker-socket-proxy"]
        self.assertTrue(proxy["read_only"])
        self.assertEqual(proxy["entrypoint"], ["haproxy"])
        self.assertEqual(proxy["networks"], ["docker-api"])
        config = (ROOT / "selfhost/monitoring/docker-api.cfg").read_text()
        pattern = next(line.split("path_reg ", 1)[1] for line in config.splitlines() if "path_reg " in line)
        self.assertIn("acl read_method method GET", config)
        self.assertIn("deny_status 403 unless read_method allowed_path", config)
        for path, allowed in (("/version", True), ("/v1.45/containers/abc123/stats", True),
                              ("/containers/abc123/archive", False), ("/containers/create", False),
                              ("/images/json", False), ("/volumes", False)):
            self.assertEqual(bool(re.fullmatch(pattern, path)), allowed, path)
        vault = yaml.safe_load((ROOT / "docker/docker-compose.traefik.yml").read_text())["services"]["vault"]
        self.assertNotEqual(vault["user"].split(":")[0], "0")
        self.assertTrue(vault["read_only"])
        self.assertTrue(any("uid=100,gid=1000" in mount for mount in vault["tmpfs"]))

    def test_grafana_credentials_require_verified_https(self):
        from urllib.error import URLError
        client = ROOT / "selfhost/monitoring/grafana-user.py"
        context = object()
        for base, transport_failure in (("https://grafana", False), ("http://grafana", False), ("https://grafana", True)):
            inputs = io.BytesIO(b"\0".join(value.encode() for value in (base, "fixture-admin-password", "remove", "observer", "")) + b"\0")
            response = unittest.mock.MagicMock()
            response.__enter__.return_value.status = 200
            response.__enter__.return_value.read.side_effect = [b'{"id":1}', b'{}']
            with self.subTest(base=base, transport_failure=transport_failure), \
                 patch("sys.stdin", SimpleNamespace(buffer=inputs)), patch("sys.stdout", io.StringIO()), \
                 patch.dict(os.environ, GRAFANA_CA_FILE="fixture-ca.crt"), \
                 patch("ssl.create_default_context", return_value=context) as tls, \
                 patch("urllib.request.urlopen", return_value=response) as request:
                if transport_failure:
                    request.side_effect = URLError("certificate verification failed")
                if base.startswith("http:") or transport_failure:
                    with self.assertRaises(SystemExit):
                        runpy.run_path(str(client))
                else:
                    runpy.run_path(str(client))
                    tls.assert_called_once_with(cafile="fixture-ca.crt")
                    self.assertTrue(all(call.kwargs["context"] is context for call in request.call_args_list))
                    self.assertEqual([call.args[0].method for call in request.call_args_list], ["GET", "DELETE"])
                if base.startswith("http:"):
                    request.assert_not_called()

    def test_jmh_malformed_and_incompatible_results_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            base, result = Path(folder) / "base.json", Path(folder) / "result.json"
            valid = [{"benchmark": "fixture", "primaryMetric": {"score": 100}}]
            base.write_text(json.dumps(valid))
            for contents, expected in (("{", 1), ('{"not":"JMH"}', 1), ('[{"benchmark":"fixture"}]', 1), (json.dumps(valid), 0)):
                result.write_text(contents)
                run = subprocess.run(["bash", str(ROOT / "scripts/jmh-regression-gate.sh"), str(base), str(result)], capture_output=True, timeout=10)
                self.assertEqual(int(run.returncode != 0), expected, run.stdout + run.stderr)

    def test_dogfood_help_and_optional_report_work_without_study(self):
        environment = dict(os.environ)
        environment.pop("CHRONICLE_STUDY_ID", None)
        for name in ("android-debug-bundle.sh", "chronicle-long-run-dogfood.sh"):
            run = subprocess.run(["bash", str(ROOT / "scripts" / name), "--help"], env=environment, capture_output=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stderr)
        with tempfile.TemporaryDirectory() as folder:
            adb = Path(folder) / "adb"
            adb.write_text("#!/usr/bin/env bash\nexit 0\n")
            adb.chmod(0o700)
            environment["ADB"] = str(adb)
            for extra in (["--no-db-report"], ["--study-id", "fixture"]):
                run = subprocess.run(["bash", str(ROOT / "scripts/android-debug-bundle.sh"), "--serial", "fixture", "--output-dir", folder, *extra], env=environment, capture_output=True, timeout=10)
                self.assertEqual(run.returncode, 0, run.stderr)

    def test_path_java_selects_native_smoke(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/chronicle-server-auth-smoke.sh", root / "scripts")
            commands = root / "bin"
            commands.mkdir()
            work = root / "work"
            work.mkdir()
            (work / "gradlew").write_text('#!/usr/bin/env bash\nprintf "native executed\\n"\n')
            (work / "gradlew").chmod(0o700)
            for name in ("java", "rsync"):
                (commands / name).write_text("#!/usr/bin/env bash\nexit 0\n")
                (commands / name).chmod(0o700)
            env = dict(os.environ, PATH=str(commands) + ":/usr/bin:/bin",
                       CHRONICLE_SERVER_SMOKE_WORKDIR=str(work), GRADLE_USER_HOME=str(root / "gradle"))
            env.pop("JAVA_HOME", None)
            env.pop("JAVA_BIN", None)
            run = subprocess.run(["bash", str(root / "scripts/chronicle-server-auth-smoke.sh")], env=env, capture_output=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn(b"native executed", run.stdout)

    def test_rollback_checks_requested_namespace(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/chronicle-rollback-smoke.sh", root / "scripts")
            child = root / "scripts/chronicle-post-deploy-smoke.sh"
            child.write_text("#!/usr/bin/env bash\nexit 0\n")
            child.chmod(0o700)
            kubectl = root / "kubectl"
            kubectl.write_text('#!/usr/bin/env bash\nif [[ "$2" == staging ]]; then echo fixture:wrong; else echo fixture:expected; fi\n')
            kubectl.chmod(0o700)
            env = dict(os.environ, KUBECTL_BIN=str(kubectl), CHRONICLE_EXPECTED_BACKEND_IMAGE="fixture:expected")
            run = subprocess.run(["bash", str(root / "scripts/chronicle-rollback-smoke.sh"), "--namespace", "staging"], env=env, capture_output=True, timeout=10)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn(b"actual=fixture:wrong", run.stdout)

    def test_release_gate_requires_explicit_predecessor_mode(self):
        env = dict(os.environ)
        env.pop("SELFHOST_SMOKE_PREVIOUS_RELEASE_ARCHIVE", None)
        env.pop("SELFHOST_SMOKE_ALLOW_SYNTHETIC_PREDECESSOR", None)
        run = subprocess.run(["bash", str(ROOT / "tests/smoke/selfhost-release-smoke.sh")], env=env, capture_output=True, timeout=10)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn(b"release mode requires a published", run.stderr)

    def test_kotlin_shorthand_plugin_drift_fails(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "scripts").mkdir()
            (root / "module").mkdir()
            shutil.copy(ROOT / "scripts/plugin-drift-detect.sh", root / "scripts")
            (root / "settings.gradle.kts").write_text('kotlin("jvm") version "2.3.0"')
            (root / "module/build.gradle.kts").write_text('kotlin("jvm") version "2.2.0"')
            run = subprocess.run(["bash", str(root / "scripts/plugin-drift-detect.sh")], env=dict(os.environ, EVENT_NAME="pull_request", PR_NUMBER=""), capture_output=True, timeout=10)
            self.assertEqual(run.returncode, 1, run.stderr)
            self.assertIn(b"org.jetbrains.kotlin.jvm is at 2.2.0", run.stdout)

    def test_diagnostic_drift_in_each_consumer_fails(self):
        import yaml
        module = importlib.util.spec_from_file_location("drift", ROOT / "tests/security/contract-drift-diff.py")
        drift = importlib.util.module_from_spec(module)
        module.loader.exec_module(drift)
        spec = yaml.safe_load((ROOT / "chronicle-api/chronicle.yaml").read_text())["components"]["schemas"]
        original = Path.read_text
        targets = ["AndroidUploadDiagnosticEvent.kt", "V113__add_access_missing_diagnostic_code.sql", "LocalUploadDiagnosticsStore.kt", "chronicle-api.generated.ts"]
        for target in targets:
            def changed(path, *args, **kwargs):
                text = original(path, *args, **kwargs)
                return text.replace("COLLECTION_ACCESS_MISSING", "COLLECTION_ACCESS_MUTATED") if path.name == target else text
            drift.failures.clear()
            with self.subTest(target=target), patch.object(Path, "read_text", changed):
                drift.check_upload_diagnostics(ROOT, copy.deepcopy(spec))
            self.assertTrue(drift.failures, target)

    def test_writable_container_root_requires_justified_exemption(self):
        with tempfile.TemporaryDirectory() as folder:
            docker = Path(folder) / "docker"
            docker.write_text('#!/usr/bin/env bash\nif [[ "$1" == ps ]]; then echo fixture; else printf "%s\\n" "$INSPECT_FIXTURE"; fi\n')
            docker.chmod(0o700)
            for readonly, reason, expected in ((False, "", 1), (False, "Required cache path; approved test exception", 0), (True, "", 0)):
                fixture = [{"Name": "/fixture", "Config": {"User": "1001", "Labels": {WRITABLE_ROOT_REASON_LABEL: reason}},
                            "HostConfig": {"ReadonlyRootfs": readonly, "CapDrop": ["ALL"], "SecurityOpt": ["no-new-privileges:true"], "Memory": 1048576}, "Mounts": []}]
                env = dict(os.environ, PATH=folder + ":/usr/bin:/bin", INSPECT_FIXTURE=json.dumps(fixture))
                run = subprocess.run(["bash", str(ROOT / "tests/security/container-security-tests.sh")], env=env, capture_output=True, timeout=10)
                self.assertEqual(run.returncode, expected, run.stdout + run.stderr)

    def test_nonweb_writable_service_fails_configuration_contract(self):
        import re
        import yaml
        source = (ROOT / "selfhost/verify-config.sh").read_text()
        code = re.search(r"service_contract_violations=\$\(python3 .*?<<'PY'\n(.*?)\nPY\n", source, re.S).group(1)
        with tempfile.TemporaryDirectory() as folder:
            compose = Path(folder) / "docker-compose.yml"
            service = {"image": "fixture", "logging": {}, "security_opt": ["no-new-privileges:true"],
                       "cap_drop": ["ALL"], "pids_limit": 64, "mem_limit": "64m"}
            for readonly, reason, passes in ((False, "", False), (False, "Reviewed writable cache requirement", True), (True, "", True)):
                service.update(read_only=readonly, labels={WRITABLE_ROOT_REASON_LABEL: reason})
                compose.write_text(yaml.safe_dump({"services": {"queue": service}}))
                run = subprocess.run([sys.executable, "-c", code, str(compose)],
                                     env=dict(os.environ, PYTHONPATH=str(ROOT / "selfhost")), capture_output=True, timeout=10)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(run.stdout.strip() == b"", passes, run.stdout)

    def test_default_database_disk_warning_without_monitoring(self):
        from chronicle_ops.verify import capacity_checks
        source = (ROOT / "selfhost/chronicle").read_text()
        self.assertNotIn('df -Pk "$PGDATA"', source)
        for free, expected in ((0, "fail"), (14, "fail"), (15, "ok"), (50, "ok")):
            result = SimpleNamespace(stdout=f'Filesystem blocks used available percent mount\ndisk 100 90 10 {100-free}% /db\n' + json.dumps({'database_bytes': 1, 'wal_bytes': 0, 'max_wal_bytes': 1}))
            with patch("chronicle_ops.verify.compose", return_value=result) as compose:
                rows = capacity_checks({}, "/unused")
            self.assertEqual(rows[0][:2], ("database-disk", expected))
            compose.assert_called_once()

    def test_unmeasured_load_baseline_cannot_pass_release_gate(self):
        run = subprocess.run(["bash", str(ROOT / "scripts/k6-regression-gate.sh"),
                              str(ROOT / "tests/perf/k6-baselines.json"), str(ROOT / "tests/perf/k6-baselines.json")],
                             env=dict(os.environ, K6_ALLOW_UNMEASURED_BUDGET="false"), capture_output=True, timeout=10)
        self.assertEqual(run.returncode, 1)
        self.assertIn(b"unmeasured", run.stderr)
        with tempfile.TemporaryDirectory() as folder:
            current = Path(folder) / "current.json"
            for contents, valid in (("{", False), ('{"metrics":{}}', False),
                                    ((ROOT / "tests/perf/k6-baselines.json").read_text(), True)):
                current.write_text(contents)
                run = subprocess.run(["bash", str(ROOT / "scripts/k6-regression-gate.sh"),
                                      str(ROOT / "tests/perf/k6-baselines.json"), str(current)],
                                     env=dict(os.environ, K6_ALLOW_UNMEASURED_BUDGET="true"), capture_output=True, timeout=10)
                self.assertEqual(run.returncode == 0, valid, run.stdout + run.stderr)

    def test_load_classification_and_minute_pacing(self):
        import re
        source = (ROOT / "tests/load/chronicle-load-test.js").read_text()
        function = re.search(r"function recordResponse\(response, surface\) \{.*?\n\}", source, re.S).group()
        code = "const records=[]; const responseClasses={add:(value,tags)=>records.push(tags)}; const check=(r,checks,tags)=>Object.values(checks).every(fn=>fn(r));\n"
        code += function + "\n"
        code += "for(const status of [200,429,401,503,0,400]) recordResponse({status},'usage');\nconsole.log(JSON.stringify(records));"
        result = subprocess.run(["bun", "-e", code], capture_output=True, check=True, timeout=10)
        records = json.loads(result.stdout)
        self.assertEqual([row["outcome"] for row in records], ["accepted", "throttled", "authentication_failed", "server_failed", "transport_failed", "request_rejected"])
        self.assertTrue(all(row["surface"] == "usage" for row in records))
        self.assertIn("UPLOAD_INTERVAL_SECONDS || '60'", source)
        self.assertIn("UPLOAD_INTERVAL_SECONDS - (Date.now() - started) / 1000", source)

    def test_load_target_uses_bound_device_credentials_and_current_payload(self):
        source = (ROOT / "tests/load/chronicle-load-test.js").read_text()
        source = re.sub(r"^import .*;\n", "", source, flags=re.M)
        source = source.replace("export default function ()", "function exerciseDevice()")
        source = re.sub(r"^export ", "", source, flags=re.M)
        device = {"participant_id": "synthetic-1", "device_id": "fixture-device", "api_key": "synthetic-credential"}
        prefix = """const requests=[], pauses=[];
const __ENV={STUDY_ID:'fixture-study', MAX_VUS:'1', DEVICE_FIXTURES_FILE:'fixture.json'};
const __VU=1;
class Counter { add() {} }; const Rate=Counter, Trend=Counter;
function SharedArray(name, read) { return read(); }
const open=()=>JSON.stringify(fixtureRows);
const randomBytes=()=>new Uint8Array(16).buffer;
const http={post:(url,body,options)=>{requests.push({url,body:JSON.parse(body),headers:options.headers});return {status:200,timings:{duration:1}}}};
const check=(response,checks)=>Object.values(checks).every(fn=>fn(response));
const group=(name,run)=>run(); const sleep=seconds=>pauses.push(seconds);
Math.random=()=>0;
"""
        for rows, valid in (([device], True), ([dict(device, api_key="")], False)):
            code = prefix + "const fixtureRows=" + json.dumps(rows) + ";\n" + source
            code += "\nsetup(); exerciseDevice(); console.log(JSON.stringify({requests,pauses}));"
            run = subprocess.run(["bun", "-e", code], capture_output=True, timeout=10)
            self.assertEqual(run.returncode == 0, valid, run.stderr)
            if valid:
                result = json.loads(run.stdout)
                usage, sensors = result["requests"]
                self.assertEqual(usage["headers"]["X-Api-Key"], device["api_key"])
                self.assertEqual(usage["headers"]["X-Chronicle-Device-Id"], device["device_id"])
                self.assertNotIn("Authorization", usage["headers"])
                self.assertEqual(usage["body"][0]["participantId"], device["participant_id"])
                self.assertEqual(usage["body"][0]["@class"], "com.openlattice.chronicle.android.ChronicleUsageEvent")
                self.assertEqual(sensors["body"][0]["sensor"], "accelerometer")
                self.assertGreater(result["pauses"][0], 59)

    def test_missing_fk_index_fails_schema_gate(self):
        script = (ROOT / "scripts/verify-schema-postconditions.sh").read_text()
        block = script[script.index('MISSING_FK_INDEXES='):script.index('echo "== 7.')]
        for output, expected in (("", 0), ("study_participants.fixture_fk", 7)):
            commands = 'psql_scalar() { printf %s "$MISSING_FIXTURE"; }; ok() { :; }; fail() { exit 7; };\n'
            run = subprocess.run(["bash", "-eu", "-c", commands + block],
                                 env=dict(os.environ, MISSING_FIXTURE=output), capture_output=True, timeout=10)
            self.assertEqual(run.returncode, expected, run.stderr)

    def test_runbooks_require_retention_purge_and_update_deadlines(self):
        deletion = (ROOT / "selfhost/docs/UNINSTALL-DATA-DELETION.md").read_text()
        for text in ("protocol retention deadline", "Delete Study", "six years", "superuser", "indefinitely", "controlled"):
            self.assertIn(text, deletion)
        guide = (ROOT / "selfhost/README.md").read_text()
        for text in ("48 hours", "7 days", "30 days", "90 days", "default-branch", "latest", "previous"):
            self.assertIn(text, guide)

    def test_nonstandard_https_redirect_uses_canonical_origin(self):
        line = next(line.strip() for line in (ROOT / "selfhost/Caddyfile.split.tls").read_text().splitlines() if 'redir {$CHRONICLE_PUBLIC_BASE_URL}' in line)
        expanded = line.replace("{$CHRONICLE_PUBLIC_BASE_URL}", "https://fixture.example:8443").replace("{uri}", "/health")
        self.assertEqual(expanded, "redir https://fixture.example:8443/health permanent")
