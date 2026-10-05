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
    def test_W64_only_audited_fixture_fingerprints_are_baselined(self):
        approved={
            'chronicle-web': [f'7ceef73c4d9c24ff985e59645d94e0e992222a61:src/modern/generated/chronicle-payload-contracts.generated.ts:generic-api-key:{line}' for line in (1031,1041,1051)],
            'methodic-root': [f'{commit}:tests/security/selfhost-deletion-status.sh:generic-api-key:{line}'
                for commit,lines in [('1837e1075e90470a5e8fd0bb2643a96312918ee2',(49,50,55)),('53fd926e60a7b6343d64bc8a91a6d3b3cfe9f051',(47,48,53)),('42f716cd59dda05f05f1372fb2ca24dc734acd14',(47,48,53))] for line in lines],
            'chronicle': ['167ff8340f8e4d0ccd3a34d1157fca2ed81fde55:app/src/test/java/com/openlattice/chronicle/collection/upload/UploadTelemetryRedactionTest.kt:generic-api-key:29']+
                [f'{commit}:collection-base/src/androidTest/java/com/openlattice/chronicle/storage/EnrollmentReplayDaoTest.kt:generic-api-key:{line}' for commit in ('167ff8340f8e4d0ccd3a34d1157fca2ed81fde55','ce2e9f5a90e4502d99fb93df7e88e717ba6d19d8','f2658a1ce187803d1ddf0aa8fdcc9fcb20bff461') for line in (124,227)],
        }
        combined=[]
        for name,rows in approved.items():
            contents=(ROOT/f'tests/security/gitleaks-ignore/{name}.gitleaksignore').read_text()
            entries={line.strip() for line in contents.splitlines() if line.strip() and not line.startswith('#')}
            self.assertTrue(set(rows).issubset(entries),name)
            combined.extend(entries)
        with tempfile.TemporaryDirectory() as d:
            import secrets
            fixture=Path(d)/'fresh.txt';fixture.write_text('api_key = "'+secrets.token_hex(32)+'"\n')
            ignore=Path(d)/'accepted-fingerprints';ignore.write_text('\n'.join(combined)+'\n')
            report=Path(d)/'redacted-findings.json'
            scan=subprocess.run(['gitleaks','dir','--no-banner','--redact=100','--gitleaks-ignore-path',str(ignore),
                '--report-format','json','--report-path',str(report),str(fixture)],capture_output=True)
            self.assertEqual(scan.returncode,1,scan.stderr.decode())
            self.assertIn('generic-api-key',{r['RuleID'] for r in json.loads(report.read_text())})

    def test_W60_nginx_locations_retain_security_headers(self):
        for path in ('k8s/base/apk-download/nginx.apk-download.conf','k8s/base/preprocessing-frontend/nginx.preprocessing.conf'):
            source=(ROOT/path).read_text()
            required=set(re.findall(r'add_header\s+(\S+)',source.split('    location',1)[0]))
            for location,body in re.findall(r'    location ([^\n]+) \{\n(.*?)\n    \}',source,re.S):
                local=set(re.findall(r'add_header\s+(\S+)',body))
                effective=local or required
                self.assertTrue(required.issubset(effective),(path,location,required-effective))

    def test_W57_configured_export_mount_and_runtime_uid(self):
        with tempfile.TemporaryDirectory() as d:
            bin_dir = Path(d)
            stub = bin_dir / 'docker'
            stub.write_text('''#!/usr/bin/env python3
import json, os, sys
a=sys.argv[1:]
if a[0]=='ps': print('chronicle-backend')
elif a[0]=='inspect':
 print(json.dumps([{'Name':'/chronicle-backend','Config':{'User':os.environ['UID_MODE'],'Env':['CHRONICLE_EXPORT_DIR='+os.environ['EXPORT_PATH']]},'HostConfig':{'CapDrop':['ALL'],'CapAdd':[],'SecurityOpt':['no-new-privileges:true'],'ReadonlyRootfs':True,'Memory':268435456},'Mounts':[{'Type':'volume','Source':'exports','Destination':os.environ['EXPORT_PATH'],'RW':os.environ['WRITABLE']=='true'}]}]))
elif a[0]=='exec':
 if 'test' in a:
  expected=['exec','-u',os.environ['UID_MODE'],'chronicle-backend','test','-w',os.environ['EXPORT_PATH']]
  sys.exit(0 if a==expected and os.environ['WRITABLE']=='true' else 1)
 else: sys.exit(1)
else: sys.exit(99)
''')
            stub.chmod(0o755)
            for path in ('/exports', '/var/lib/chronicle/exports'):
                for uid in ('100:101', 'chronicle'):
                    for writable in ('true','false'):
                        result = subprocess.run(['bash',str(ROOT/'tests/security/container-security-tests.sh')],
                            env={**os.environ,'PATH':str(bin_dir)+':'+os.environ['PATH'],
                                 'EXPORT_PATH':path,'UID_MODE':uid,'WRITABLE':writable},capture_output=True)
                        self.assertEqual(result.returncode==0,writable=='true',result.stdout.decode()+result.stderr.decode())

    def test_W58_policy_units_and_gate_failure(self):
        result = subprocess.run(['conftest','verify','--policy',str(ROOT/'tests/security/policies')],capture_output=True)
        self.assertEqual(result.returncode,0,result.stdout.decode()+result.stderr.decode())
        gate = function('tests/security/run-all-security.sh','run_compliance_scan')
        with tempfile.TemporaryDirectory() as d:
            shell = 'set -euo pipefail\nconftest() { echo "$1" >>"$CALLS"; [[ "$1" != verify ]]; }\n'+gate+'\nrun_compliance_scan\n'
            result = subprocess.run(['bash','-c',shell],env={**os.environ,'ROOT_DIR':str(ROOT),'REPORT_DIR':d,'CALLS':d+'/calls'},capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(Path(d+'/calls').read_text().splitlines(),['verify'])

    def test_W59_shipped_gate_coverage(self):
        methods = '\n'.join(function('scripts/local-ci.sh',n) for n in ('deployment_files','job_dockerfile_lint','job_iac_scan'))
        with tempfile.TemporaryDirectory() as d:
            fixture = Path(d)
            for name in ('docker/Dockerfile.backend','selfhost/Dockerfile.caddy','selfhost/overlays/sample.yml','k8s/overlays/test/kustomization.yaml','selfhost/entrypoint.sh'):
                p=fixture/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('clean')
            stub = '''set -euo pipefail
ensure_hadolint() { :; }; prepare_checkov_runtime() { :; }; require_cmd() { :; }
report_path() { printf '%s/%s' "$ROOT_DIR" "$2"; }
scanner() { for a in "$@"; do [[ ! -f "$a" ]] || ! rg -q VIOLATION "$a" || return 1; done; }
hadolint() { scanner "$@"; }; shellcheck() { scanner "$@"; }
conftest() { scanner "$@"; }; checkov() { scanner "$@"; }
kustomize() { cat "$2/kustomization.yaml"; }
'''
            env={**os.environ,'ROOT_DIR':d}
            def run():
                return subprocess.run(['bash','-c',stub+methods+'\njob_dockerfile_lint\njob_iac_scan'],env=env,capture_output=True)
            self.assertEqual(run().returncode,0)
            for name in ('selfhost/Dockerfile.caddy','selfhost/overlays/sample.yml','k8s/overlays/test/kustomization.yaml','selfhost/entrypoint.sh'):
                p=fixture/name;p.write_text('VIOLATION')
                self.assertNotEqual(run().returncode,0,name)
                p.write_text('clean')

    def test_W63_local_requests_have_absolute_deadlines(self):
        source=(ROOT/'scripts/local-ci.sh').read_text()
        # Every actual curl call must bound the transfer as well as the connection.
        calls=re.findall(r'^[ \t]*[^#\n]*?\bcurl[ \t]+((?:[^\n]*\\\n)*[^\n]*)',source,re.M)
        self.assertGreaterEqual(len(calls),5)
        for call in calls:
            self.assertRegex(call,r'--max-time\s+[1-9][0-9]*')
            self.assertRegex(call,r'--connect-timeout\s+[1-9][0-9]*')
        with tempfile.TemporaryDirectory() as d:
            stub='set -euo pipefail\nrequire_cmd() { :; }; curl() { [[ "$*" == *"--max-time"* && "$*" == *"--connect-timeout"* ]] || return 99; return 28; }\n'
            result=subprocess.run(['bash','-c',stub+function('scripts/local-ci.sh','download_asset')+'\ndownload_asset https://fixture.invalid artifact'],env={**os.environ,'TMPDIR':d},capture_output=True,timeout=2)
            self.assertEqual(result.returncode,28)

    def test_W65_android_sast_modules_and_candidate_license(self):
        source=(ROOT/'tests/security/run-all-security.sh').read_text()
        sast=function('tests/security/run-all-security.sh','run_sast_semgrep')
        modules=function('tests/security/run-all-security.sh','android_source_roots')
        modular=function('tests/security/run-all-security.sh','run_collection_semgrep_modularization')
        self.assertIn('android_source_roots',sast)
        self.assertIn('android_source_roots',modular)
        self.assertIn('find',modules)
        job=function('scripts/local-ci.sh','job_android_unit')
        self.assertIn(':app:checkLicense',job)
        self.assertIn('run-all-security.sh',job)
        rule=(ROOT/'tests/security/collection-rules/collection-modularization.yaml').read_text()
        self.assertIn('override val privacyClass: CollectionPrivacyClass = $ID.privacyClass',rule)
        with tempfile.TemporaryDirectory() as d:
            shell='''set -euo pipefail
require_jdk21() { :; }; log() { :; }
'''+job.replace('bash "$ROOT_DIR/tests/security/run-all-security.sh" sast','printf sast >>"$CALLS"')+'\njob_android_unit'
            root=Path(d);(root/'chronicle').mkdir()
            gradle=root/'chronicle/gradlew'
            gradle.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >>"$CALLS"\n[[ "$*" != *":app:checkLicense"* ]]\n');gradle.chmod(0o755)
            result=subprocess.run(['bash','-c',shell],env={**os.environ,'ROOT_DIR':d,'CALLS':d+'/calls'},capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn(':app:checkLicense',(root/'calls').read_text())
            selected=[]
            for path in ('tests/security/rules/cwe-comprehensive.yaml','tests/security/collection-rules/collection-modularization.yaml'):
                rules=yaml.safe_load((ROOT/path).read_text())['rules']
                selected.extend(r for r in rules if r['id'] in ('chronicle-android-log-raw-participant-id','chronicle-collection-module-must-assert-privacy-invariant'))
            config=root/'rules.yaml';config.write_text(yaml.safe_dump({'rules':selected}))
            scan_parent=ROOT/'audit-regression-runs';scan_parent.mkdir(exist_ok=True)
            with tempfile.TemporaryDirectory(dir=scan_parent) as scan_dir:
                fixture=Path(scan_dir)/'chronicle/collection-activity/src/main/java/fixture';fixture.mkdir(parents=True)
                valid=fixture/'Valid.kt';valid.write_text('class Valid : DataCollectionModule { override val privacyClass: CollectionPrivacyClass = id.privacyClass }')
                invalid=fixture/'Invalid.kt';invalid.write_text('class Invalid : DataCollectionModule { fun log(participantId: String) { Log.i("tag", "$participantId") } }')
                scan=subprocess.run(['semgrep','scan','--config',str(config),'--metrics','off','--disable-version-check','--no-git-ignore','--json','.'],cwd=fixture,env={**os.environ,'SEMGREP_SEND_METRICS':'off'},capture_output=True)
                self.assertEqual(scan.returncode,0,scan.stderr.decode())
                findings=json.loads(scan.stdout)['results']
                self.assertEqual({Path(r['path']).name for r in findings},{'Invalid.kt'},scan.stderr.decode()+scan.stdout.decode())
                self.assertEqual(len(findings),2,scan.stderr.decode()+scan.stdout.decode())

    def test_W75_observed_secure_v3_cookie_required(self):
        with tempfile.TemporaryDirectory() as d:
            stub=Path(d)/'curl'
            stub.write_text('''#!/usr/bin/env python3
import os, sys
a=sys.argv[1:]; mode=os.environ['RESPONSE_MODE']; url=a[-1]
if '--data-binary' in a: sys.stdin.read()
if mode=='unreachable': print('000',end=''); sys.exit(7)
if '-D' in a and a[a.index('-D')+1]!='-':
 headers=a[a.index('-D')+1]; body=a[a.index('-o')+1]
 status='404' if mode=='404' else '200'
 assert url.endswith('/chronicle/v3/auth/set-cookie'),url
 cookie='' if mode=='no-cookie' else 'Set-Cookie: chronicle_auth=synthetic; HttpOnly; '+('Secure; SameSite=Lax' if mode=='secure' else 'SameSite=None')+'\\r\\n'
 open(headers,'w').write('HTTP/1.1 '+status+' OK\\r\\n'+cookie+'\\r\\n')
 open(body,'w').write('{"authenticated":true}')
 print(status,end='')
elif '-D' in a: print('HTTP/1.1 404 Not Found\\r\\n\\r\\n',end='')
else: print('200' if url.endswith('/chronicle/v3/auth/session') or url.endswith('/chronicle/v3/') else '401',end='')
''');stub.chmod(0o755)
            for mode in ('unreachable','404','no-cookie','insecure','secure'):
                result=subprocess.run(['bash',str(ROOT/'tests/security/session-management-tests.sh')],env={**os.environ,'PATH':d+':'+os.environ['PATH'],'BASE_URL':'https://fixture.invalid','AUTH_TOKEN':'synthetic.jwt.token','JWT_SECRET':'synthetic-secret','RESPONSE_MODE':mode},capture_output=True)
                self.assertEqual(result.returncode==0,mode=='secure',result.stdout.decode()+result.stderr.decode())

if __name__ == '__main__':
    unittest.main()
