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
