#!/usr/bin/env python3
"""Offline gate regressions with synthetic CLI responses only."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
RUNS = ROOT / 'build/operator-test-runs/webselfhost-gates'
RUNS.mkdir(parents=True, exist_ok=True)
os.environ['TMPDIR'] = str(RUNS)
tempfile.tempdir = str(RUNS)

def function(path, name):
    source = (ROOT / path).read_text()
    match = re.search(r'^' + name + r'\(\) \{.*?^\}', source, re.M | re.S)
    if not match:
        raise AssertionError('missing function ' + name)
    return match.group()

class GateRegressions(unittest.TestCase):
    def test_W60_nginx_locations_retain_security_headers(self):
        for path in ('k8s/base/apk-download/nginx.apk-download.conf','k8s/base/preprocessing-frontend/nginx.preprocessing.conf'):
            source=(ROOT/path).read_text()
            required=set(re.findall(r'add_header\s+(\S+)',source.split('    location',1)[0]))
            for location,body in re.findall(r'    location ([^\n]+) \{\n(.*?)\n    \}',source,re.S):
                local=set(re.findall(r'add_header\s+(\S+)',body))
                effective=local or required
                self.assertTrue(required.issubset(effective),(path,location,required-effective))


if __name__ == '__main__':
    unittest.main()
