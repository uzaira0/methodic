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
