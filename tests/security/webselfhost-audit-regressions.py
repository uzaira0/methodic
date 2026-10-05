#!/usr/bin/env python3
"""Isolated launch-audit regressions; never contacts a deployment."""
import ast
import secrets
import itertools
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUNS = ROOT / 'build/operator-test-runs/webselfhost-audit'
RUNS.mkdir(parents=True, exist_ok=True)
os.environ['TMPDIR'] = str(RUNS)
tempfile.tempdir = str(RUNS)

class AuditRegressions(unittest.TestCase):
    def test_cross_S03_contract2_refused_before_drop(self):
        source = (ROOT / 'selfhost/restore.sh').read_text()
        branch = source.split('else\n  checkpoint_rows=', 1)[1].split('\nfi\n\n# Treat a resumed', 1)[0]
        shell = '''set -euo pipefail
psql_q() { if [[ "$*" == *contract_version* ]]; then printf '%s' "$CONTRACT"; else printf 1; fi; }
checkpoint_rows=''' + branch + '\nprintf accepted > "$MARKER"\n'
        with tempfile.TemporaryDirectory() as d:
            for contract in ('2', '3', 'unknown'):
                marker = Path(d) / contract
                result = subprocess.run(['bash', '-c', shell], env={**os.environ,
                    'CONTRACT': contract, 'MARKER': str(marker)}, capture_output=True)
                self.assertEqual(result.returncode == 0, contract == '3', result.stderr.decode())
                self.assertEqual(marker.exists(), contract == '3')

    def test_W01_rollback_consumes_only_complete_checkpoint(self):
        source = (ROOT / 'selfhost/restore.sh').read_text()
        block = source[source.index('if [[ "${CHRONICLE_RESTORE_LEAVE_STOPPED'):source.index('# 7. Report')]
        self.assertIn('DROP SCHEMA chronicle_restore_continuity', block)
        self.assertIn('BEGIN;', block)
        self.assertIn('COMMIT;', block)
        canonical = re.findall(r'WITH canonical\(line\) AS \((.*?)\), digest AS \(', source, re.S)
        self.assertEqual(len(canonical), 2)
        self.assertEqual(re.sub(r'\s+', ' ', canonical[0]).strip(), re.sub(r'\s+', ' ', canonical[1]).strip())
        self.assertIn('actual_digest IS DISTINCT FROM expected.checkpoint_sha256', block)
        self.assertIn('to_jsonb(target) @> to_jsonb(source)', block)
        for table in ('withdrawal_requests', 'revoked_api_keys', 'withdrawn_participants',
                      'deletion_operations', 'retention_holds', 'deletion_tombstones',
                      'data_collection_settings_revisions', 'published_data_collection_settings',
                      'enrollment_invitations', 'erased_device_key_tombstones'):
            self.assertIn('chronicle_restore_continuity.' + table, block)
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / 'rollback.sh'
            script.write_text('set -euo pipefail\npsql_q() {\n sql=$(cat)\n [[ "$sql" == *"RAISE EXCEPTION"* && "$sql" == *"DROP SCHEMA"* ]] || exit 90\n [[ "$PROOF" == complete ]] || return 1\n printf consumed >"$MARKER"\n}\n' + block)
            for proof in ('complete', 'unknown', 'incomplete'):
                marker = Path(d) / proof
                result = subprocess.run(['bash', str(script)], env={**os.environ,
                    'CHRONICLE_RESTORE_LEAVE_STOPPED': 'true', 'PROOF': proof, 'MARKER': str(marker)}, capture_output=True)
                self.assertEqual(result.returncode == 0, proof == 'complete')
                self.assertEqual(marker.exists(), proof == 'complete')

    def test_W02_shares_are_data_and_validated(self):
        source = (ROOT / 'docker/key-recovery.sh').read_text()
        function = source[source.index('python_combine() {'):source.index('# ── Reconstruct key')]
        with tempfile.TemporaryDirectory() as d:
            marker = Path(d) / 'injected'
            good = ['1-001122', '2-112233', '3-223344']
            hostile = '1-00"""; open(' + repr(str(marker)) + ', "w").write("injected"); #'
            for values in ([hostile, *good[1:]], ['1-00','1-11','3-22'],
                           ['0-00','2-11','3-22'], ['256-00','2-11','3-22'],
                           ['1-zz','2-11','3-22'], ['1-00','2-1122','3-22'],
                           [*good,'4-nothex']):
                files = []
                for n, value in enumerate(values):
                    path = Path(d) / f'share-{n}.txt'; path.write_text(value + '\n'); files.append(str(path))
                result = subprocess.run(['bash','-c', function + '\npython_combine 3 "$@"','combine',*files],capture_output=True)
                self.assertNotEqual(result.returncode, 0, values)
                self.assertFalse(marker.exists())

    def test_W03_rotation_updates_authority_and_rolls_back(self):
        source = (ROOT / 'scripts/rotate-secrets.sh').read_text()
        self.assertTrue('${CHRONICLE_ENV_FILE:-./.env}' in (ROOT / 'docker/docker-compose.traefik.yml').read_text(), 'Compose must consume the selected protected env file')
        helper = source[source.index('file_mode() {'):source.index('# ── Pre-flight')]
        restart = source[source.index('restart_services() {'):source.index('# Guard: under')]
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); secrets = root / 'secrets'; secrets.mkdir()
            (root / 'before').write_text('JWT_SECRET=old\n')
            (root / 'env').write_text('JWT_SECRET=old\n')
            (root / 'new').write_text('new'); (secrets / 'jwt_secret').write_text('old')
            for path in (root / 'env',root / 'new',secrets / 'jwt_secret'): path.chmod(0o600)
            shell = 'set -euo pipefail\nlog() { :; }; warn() { :; }; err() { echo "$*" >&2; exit 1; }; DRY_RUN=false\n' + helper + '\ntrap - EXIT\n' + restart + '\n'
            shell += 'declare -A RESTART_NEEDED=([chronicle-backend]=1)\nenv_set JWT_SECRET "$NEW"\n[[ $(cat "$SECRET_DIR/jwt_secret") == new ]] || exit 81\nrestart_services\n'
            env = {**os.environ,'ENV_FILE':str(root / 'env'),'SECRET_DIR':str(secrets),
                   'BACKUP_DIR':str(root),'ENV_BACKUP':str(root / 'before'),'NEW':str(root / 'new')}
            # Stub only the Compose and credential checks; the file updates remain real.
            shell = shell.replace('dc() { docker compose', 'dc() { docker compose')
            stub = 'docker() { if [[ \"$*\" == *\"config --services\"* ]]; then echo chronicle-backend; return; fi; [[ "$*" == *"up -d --force-recreate --wait"* ]] || return 99; [[ "$FAIL_HEALTH" != true ]]; }; COMPOSE_FILE=fixture; FAIL_HEALTH=false\n'
            result = subprocess.run(['bash','-c',stub + shell],env=env,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr.decode())
            self.assertEqual((secrets / 'jwt_secret').read_text(),'new')
            # Rollback restores both sources after an unsuccessful health wait.
            rollback = source[source.index('rollback_rotation() {'):source.index('# ── Individual rotation')]
            result = subprocess.run(['bash','-c',stub + shell.split('declare -A RESTART_NEEDED')[0] + rollback + '\nrollback_rotation\n'],env=env,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr.decode())
            self.assertEqual((root / 'env').read_text(),'JWT_SECRET=old\n')
            self.assertEqual((secrets / 'jwt_secret').read_text(),'old')

        # Exercise the actual stdin reader and EXIT compensator after a failed health wait.
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); secret_dir = root / 'secrets'; secret_dir.mkdir()
            initial = 'POSTGRES_USER=chronicle\nPOSTGRES_DB=chronicle\nPOSTGRES_PASSWORD=old-password\n'
            for name in ('env','before'):
                (root/name).write_text(initial); (root/name).chmod(0o600)
            (secret_dir/'postgres_password').write_text('old-password'); (secret_dir/'postgres_password').chmod(0o600)
            (root/'db-password').write_text('old-password')
            bin_dir=root/'bin'; bin_dir.mkdir()
            psql_stub=bin_dir/'psql'
            psql_stub.write_text("#!/usr/bin/env python3\nimport os,pathlib,re,sys\np=pathlib.Path(os.environ['DB_PASSWORD'])\nassert os.environ['PGPASSWORD']==p.read_text()\nif 'SELECT 1' not in ' '.join(sys.argv):\n text=sys.stdin.read()\n match=re.search(r\"new_password '([^']+)'\",text)\n p.write_text(match.group(1) if match else 'old-password')\n if match and os.environ.get('ALTER_RESPONSE_LOST') == 'true': sys.exit(28)\n")
            psql_stub.chmod(0o755)
            pg_rotate=source[source.index('rotate_postgres_password() {'):source.index('rotate_jwt_secret() {')]
            rollback=source[source.index('rollback_rotation() {'):source.index('# ── Individual rotation')]
            stub=r'''log() { :; }; warn() { :; }; err() { exit 1; }
export DB_PASSWORD
# Only the Compose API and container transport are replaced. Run its real sh stdin reader.
docker() {
  if [[ "$1" == compose ]]; then
    if [[ "$*" == *"config --services"* ]]; then printf 'postgres\nchronicle-backend\n'; return; fi
    [[ "$*" == *"--env-file $ENV_FILE"* && "$CHRONICLE_ENV_FILE" == "$ENV_FILE" && "$*" == *"--force-recreate --wait"* ]] || return 92
    if [[ ! -f "$HEALTH_FAILURE" ]]; then touch "$HEALTH_FAILURE"; return 1; fi
    return 0
  fi
  [[ "$1 $2 $3" == "exec -i chronicle-postgres" ]] || return 93
  shift 3
  "$@"
}
'''
            shell='set -euo pipefail\nDRY_RUN=false\nCOMPOSE_FILE=fixture\n'+stub+helper+'\n'+rollback+'\n'+restart+'\n'+pg_rotate+'\ndeclare -A RESTART_NEEDED=()\nrotate_postgres_password\nrestart_services || err health\nrotation_committed=true\n'
            env={**os.environ,'ENV_FILE':str(root/'env'),'ENV_BACKUP':str(root/'before'),
                 'SECRET_DIR':str(secret_dir),'BACKUP_DIR':str(root),'DB_PASSWORD':str(root/'db-password'),
                 'HEALTH_FAILURE':str(root/'failed-once'),'PATH':str(bin_dir)+':'+os.environ['PATH']}
            (root/'failed-once').touch()
            success=subprocess.run(['bash','-c',shell],env=env,capture_output=True)
            self.assertEqual(success.returncode,0,success.stderr.decode())
            self.assertNotEqual((root/'db-password').read_text(),'old-password')
            self.assertEqual((root/'db-password').read_text(),(secret_dir/'postgres_password').read_text().strip())
            (root/'env').write_text(initial)
            (root/'db-password').write_text('old-password')
            (secret_dir/'postgres_password').write_text('old-password')
            (root/'failed-once').unlink()
            result=subprocess.run(['bash','-c',shell],env=env,capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertTrue((root/'failed-once').exists(),result.stderr.decode())
            self.assertEqual((root/'db-password').read_text(),'old-password',result.stderr.decode())
            self.assertEqual((root/'env').read_text(),initial)
            self.assertEqual((secret_dir/'postgres_password').read_text(),'old-password')
            # The forward ALTER commits, but the transport loses its reply. The
            # compensator must try the generated credential even before env_set.
            lost = subprocess.run(['bash','-c',shell],env={**env,'ALTER_RESPONSE_LOST':'true'},capture_output=True)
            self.assertNotEqual(lost.returncode,0)
            self.assertEqual((root/'db-password').read_text(),'old-password',lost.stderr.decode())
            self.assertEqual((root/'env').read_text(),initial)
            self.assertEqual((secret_dir/'postgres_password').read_text(),'old-password')

    def test_W04_all_inverses_and_threshold_subsets(self):
        implementations = []
        for name in ('docker/key-recovery.sh','docker/key-ceremony.sh'):
            source = (ROOT / name).read_text()
            bodies = re.findall(r"<<'PYEOF'\n(.*?)\nPYEOF",source,re.S)
            for body in bodies:
                tree = ast.parse(body)
                functions = [node for node in tree.body if isinstance(node,ast.FunctionDef)]
                if not any(node.name == 'gf256_inv' for node in functions): continue
                scope = {'secrets':secrets}
                exec(compile(ast.Module(body=functions,type_ignores=[]),name,'exec'),scope)
                for a in range(1,256):
                    self.assertEqual(scope['gf256_mul'](a,scope['gf256_inv'](a)),1,(name,a))
                implementations.append(scope)
        splitter = next(scope for scope in implementations if 'make_shares' in scope)
        secret = bytes(range(16))
        shares = splitter['make_shares'](secret,3,5)
        for scope in implementations:
            if 'lagrange_interpolate' not in scope: continue
            for subset in itertools.combinations(range(5),3):
                recovered = bytes(scope['lagrange_interpolate']([(n+1,shares[n][pos]) for n in subset],3) for pos in range(len(secret)))
                self.assertEqual(recovered,secret)

    def test_W05_backup_passphrase_roundtrips_bytes(self):
        source = (ROOT / 'docker/key-recovery.sh').read_text()
        block = source[source.index('if [ "$KEY_TYPE" = "backup" ] &&'):source.index('# ── Summary')]
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); original = root / 'original'; destination = root / 'recovered'
            block = block.replace('/etc/chronicle/backup-encryption-key', str(destination)).replace('/etc/chronicle', str(root))
            original.write_bytes(b'synthetic-passphrase-with-newline\n')
            import io, tarfile
            with tarfile.open(root / 'dump.gz','w:gz') as archive:
                info = tarfile.TarInfo('database.dump'); content = b'synthetic-backup'; info.size = len(content)
                archive.addfile(info,io.BytesIO(content))
            encrypted = root / 'dump.enc'
            subprocess.run(['openssl','enc','-aes-256-cbc','-salt','-pbkdf2','-iter','600000',
                '-in',str(root / 'dump.gz'),'-out',str(encrypted),'-pass','file:'+str(original)],check=True,capture_output=True)
            # sudo is a local function; no privileged commands or external destination.
            prefix = 'set -euo pipefail\nsudo() { if [[ "$1" == chown ]]; then return; fi; "$@"; }; log() { :; }; log_ok() { :; }; log_err() { :; }; KEY_TYPE=backup; WRITE_KEY_FILE=true\n'
            for valid in (True, False):
                destination.write_bytes(b'previous-destination')
                recovered = original.read_bytes().hex() if valid else b'wrong-passphrase'.hex()
                env = {**os.environ,'RECOVERED_KEY':recovered,'BACKUP_KEY_DESTINATION':str(destination),
                    'VERIFY_BACKUP':str(encrypted),'BACKUP_REPRESENTATION':'passphrase-file-bytes','FINGERPRINT':'synthetic-validated'}
                result = subprocess.run(['bash','-c',prefix+block],env=env,capture_output=True)
                self.assertEqual(result.returncode == 0,valid)
                self.assertEqual(destination.read_bytes(),original.read_bytes() if valid else b'previous-destination')

            # Exercise the actual ceremony, shares, CLI fingerprint gate and the
            # older 100k backup format together using only synthetic local files.
            import json
            ceremony = root / 'ceremony'
            made = subprocess.run(['bash', str(ROOT / 'docker/key-ceremony.sh'),
                '--tde-key', '00' * 32, '--backup-key-file', str(original),
                '--output-dir', str(ceremony)], capture_output=True)
            self.assertEqual(made.returncode, 0, made.stderr.decode())
            record = json.loads((ceremony / 'ceremony-record.json').read_text())
            self.assertEqual(record['backup_key_representation'], 'passphrase-file-bytes')
            subprocess.run(['openssl','enc','-aes-256-cbc','-salt','-pbkdf2','-iter','100000',
                '-in',str(root / 'dump.gz'),'-out',str(encrypted),'-pass','file:'+str(original)],
                check=True, capture_output=True)
            commands = root / 'bin'; commands.mkdir()
            sudo = commands / 'sudo'
            sudo.write_text('#!/usr/bin/env bash\nif [[ "$1" == chown ]]; then exit 0; fi\nexec "$@"\n')
            sudo.chmod(0o755)
            base = ['bash', str(ROOT / 'docker/key-recovery.sh'), '--type', 'backup', '--shares',
                *(str(ceremony / 'backup-shares' / f'share-{n}.txt') for n in (1, 3, 5)),
                '--write-key-file', '--representation', 'passphrase-file-bytes',
                '--verify-backup', str(encrypted)]
            env = {**os.environ, 'PATH': str(commands) + ':' + os.environ['PATH'],
                'BACKUP_KEY_DESTINATION': str(destination)}
            for fingerprint, accepted in ((None, False), ('0' * 64, False),
                                         (record['backup_key_fingerprint_sha256'], True)):
                destination.write_bytes(b'previous-destination')
                args = base + (['--fingerprint', fingerprint] if fingerprint else [])
                recovered = subprocess.run(args, env=env, capture_output=True)
                self.assertEqual(recovered.returncode == 0, accepted, recovered.stderr.decode())
                self.assertEqual(destination.read_bytes(), original.read_bytes() if accepted else b'previous-destination')

    def test_W14_only_reviewed_restricted_dumps_restore(self):
        import gzip, hashlib
        host = (ROOT / 'selfhost/chronicle').read_text()
        container = (ROOT / 'selfhost/restore.sh').read_text()
        self.assertIn('verify_restore_dump "$restore_host_path"',host)
        self.assertLess(host.index('verify_restore_dump "$restore_host_path"'),host.index('Stopping application access'))
        self.assertIn('verify_restore_dump "$RESTORE_FILE"',container)
        function = container[container.index('verify_restore_dump() {'):container.index('# ---------------------------------------------------------------------------------------')]
        with tempfile.TemporaryDirectory() as d:
            for payload, accepted in [(b'-- PostgreSQL database dump\n\\restrict token123\nSELECT 1;\n\\unrestrict token123\n',True),
                (b'-- PostgreSQL database dump\n\\restrict token123\nCOPY public.x FROM stdin;\n\\! this-is-copy-data\n\\.\n\\unrestrict token123\n',True),
                (b'-- PostgreSQL database dump\n\\restrict token123\n\\! touch owned\n\\unrestrict token123\n',False),
                (b"-- PostgreSQL database dump\n\\restrict token123\nCOPY x FROM PROGRAM 'touch owned';\n\\unrestrict token123\n",False),
                (b'-- PostgreSQL database dump\n\\restrict token123\nSELECT 1; \\unrestrict token123\nSELECT 1; \\! touch owned\n\\unrestrict token123\n',False),
                (b'SELECT 1;\n',False)]:
                dump = Path(d) / 'dump.gz'; dump.write_bytes(gzip.compress(payload))
                for trusted in (True,False):
                    digest = hashlib.sha256(dump.read_bytes()).hexdigest() if trusted else '0'*64
                    result = subprocess.run(['bash','-c',function+'\nverify_restore_dump "$1" "$2"','verify',str(dump),digest],capture_output=True)
                    self.assertEqual(result.returncode==0,accepted and trusted,result.stderr.decode())

    def test_W31_independent_monitoring_guard(self):
        source = (ROOT / 'selfhost/monitoring/render-config.sh').read_text()
        compose = (ROOT / 'selfhost/overlays/monitoring.yml').read_text()
        service = compose[compose.index('  monitoring-config:'):compose.index('  # Read-only Docker API')]
        self.assertIn('GRAFANA_BIND:',service)
        self.assertIn('GRAFANA_ADMIN_PASSWORD:',service)
        preflight = source[:source.index('mkdir -p /monitoring-secrets')]
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / 'render.sh'
            script.write_text(preflight.replace('$(dirname \"${BASH_SOURCE[0]}\")/../network-policy.sh', str(ROOT / 'selfhost/network-policy.sh')) + '\nprintf accepted\n')
            for bind,password,accepted in [('0.0.0.0','short',False),('::0','x'*32,False),
                ('127.0.0.1','x'*32,True),('10.1.2.3','x'*32,True)]:
                result = subprocess.run(['bash',str(script)],env={**os.environ,
                    'METRICS_PASSWORD':'x'*32,'GRAFANA_ADMIN_PASSWORD':password,'GRAFANA_BIND':bind},capture_output=True)
                self.assertEqual(result.returncode==0,accepted,result.stderr.decode())

    def test_W56_canonical_bind_and_cidr_union(self):
        guard = (ROOT / 'selfhost/guard-config.sh').read_text()
        self.assertIn('specific_private_bind "$INTERNAL_BIND"',guard)
        self.assertIn('validate_dashboard_networks "$DASHBOARD_ALLOWED_IPS"',guard)
        policy = ROOT / 'selfhost/network-policy.sh'
        for bind,accepted in [('0.0.0.0',False),('0.00.0.00',False),('::',False),('::0',False),
            ('[0:0:0:0:0:0:0:0]',False),('::ffff:0.0.0.0',False),('127.0.0.1',True),
            ('10.1.2.3',True),('192.168.5.6',True),('::1',True),('0:0:0:0:0:0:0:1',True),('fd12::1234',True)]:
            result = subprocess.run(['bash','-c','source "$1"; specific_private_bind "$2"','policy',str(policy),bind],capture_output=True)
            self.assertEqual(result.returncode==0,accepted,bind)
        for networks,accepted in [('0.0.0.0/1 128.0.0.0/1',False),('::/1 8000::/1',False),
            ('0.0.0.0/2 64.0.0.0/2 128.0.0.0/2 192.0.0.0/2',False),
            ('192.168.0.0/16 ::1/128',True),('10.0.0.0/8',True),('invalid/3',False)]:
            result = subprocess.run(['bash','-c','source "$1"; validate_dashboard_networks "$2"','policy',str(policy),networks],capture_output=True)
            self.assertEqual(result.returncode==0,accepted,networks)


if __name__ == '__main__':
    unittest.main()
