import ast
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "selfhost"))
from chronicle_ops.reconcile import ENABLED_ENV
from chronicle_ops.release import RELEASE_SIGNER
from test_release import complete_update_fixture


def update_code():
    source = (ROOT / 'selfhost/chronicle').read_text()
    start = source.index('import json\n', source.index('cmd_update() {'))
    return compile(source[start:source.index('\nPY\n}', start)], 'update-fixture', 'exec')


class LauncherTests(unittest.TestCase):
    def setUp(self):
        disabled = patch.dict(os.environ, {ENABLED_ENV: "false"})
        disabled.start()
        self.addCleanup(disabled.stop)

    def test_setup_prints_the_installed_public_fingerprint_and_docs_match(self):
        fingerprint = subprocess.run(['ssh-keygen', '-lf', str(ROOT / 'selfhost/release-signing.pub')],
                                     check=True, capture_output=True, text=True).stdout.split()[1]
        for document in ('SECURITY.md', 'selfhost/README.md'):
            self.assertIn(fingerprint, (ROOT / document).read_text())
        source = (ROOT / 'selfhost/chronicle').read_text()
        setup = source[source.index('cmd_setup() {'):source.index('  begin_operation setup')]
        result = subprocess.run(['bash', '-c', 'die() { exit 1; }; ' + setup + '}\ncmd_setup setup'],
                                cwd=ROOT / 'selfhost', check=True, capture_output=True, text=True)
        self.assertIn(fingerprint, result.stdout)
        self.assertIn('independent institution handoff', result.stdout)

    def test_update_verifies_installed_key_before_extraction_without_bytecode(self):
        runs = ROOT / "build/operator-test-runs/selfhost-launcher"
        runs.mkdir(parents=True, exist_ok=True)
        cases = (("1.2.4", ["--check"], "valid", 3),
                 ("1.2.3", ["--check"], "valid", 0),
                 ("1.2.4", [], "valid", 0),
                 ("1.2.4", [], "tampered-checksum", 1),
                 ("1.2.4", [], "missing-signature", 1),
                 ("1.2.4", [], "unavailable-signature", 1),
                 ("1.2.4", [], "foreign-signature", 1),
                 ("1.2.4", [], "missing-installed-key", 1),
                 ("1.2.4", [], "killed-download", 137),
                 ("1.2.4", [], "killed-extraction", 137),
                 ("1.2.4", [], "asset-remnant", 0))
        for latest, arguments, scenario, expected_status in cases:
            with self.subTest(scenario=scenario, latest=latest, arguments=arguments), tempfile.TemporaryDirectory(dir=runs) as d:
                root = Path(d)
                release = root / "releases/current"
                selfhost = release / "selfhost"
                selfhost.mkdir(parents=True)
                shutil.copy2(ROOT / "selfhost/chronicle", selfhost / "chronicle")
                shutil.copytree(ROOT / "selfhost/chronicle_ops", selfhost / "chronicle_ops",
                                ignore=shutil.ignore_patterns("__pycache__"))
                (release / "release-manifest.json").write_text(json.dumps({"release_version": "1.2.3"}))
                state = root / 'deployment-state'; state.mkdir()
                (selfhost / '.env').write_text(f"COMPOSE_PROJECT_NAME=study-production\nCHRONICLE_STATE_DIR='{state}'\nMIN_FREE_DISK_GIB=0\n")
                (selfhost / '.env').chmod(0o600)
                environment = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                                   CHRONICLE_RELEASES_URL="https://updates.invalid/latest.json",
                                   CURL_FIXTURE_DIR=str(root / "http"),
                                   UPDATE_EXEC_RECORD=str(root / "handoff"))
                for key in ("PYTHONDONTWRITEBYTECODE", "PYTHONPYCACHEPREFIX"):
                    environment.pop(key, None)
                fixture = subprocess.run(["bash", "-c",
                    'source "$1"; write_update_curl_fixture "$2"; write_update_fixture "$3" 1.2.3 "$4"',
                    "fixture", str(ROOT / "tests/security/lib/selfhost-fixtures.sh"),
                    str(root / "bin"), str(root / "http"), latest], env=environment, capture_output=True)
                self.assertEqual(fixture.returncode, 0, fixture.stderr.decode())
                complete_update_fixture(root, latest)
                if scenario == 'killed-download':
                    curl = root / 'bin/curl'
                    curl.write_text(curl.read_text().replace('case "$url" in', '''
if [[ "${KILL_DOWNLOAD:-false}" == true && "$name" == *.tar.gz ]]; then
  printf 'partial archive'
  kill -KILL "$PPID"
  exit 137
fi
case "$url" in'''))
                    environment['KILL_DOWNLOAD'] = 'true'
                elif scenario == 'killed-extraction':
                    operator = selfhost / 'chronicle'
                    operator.write_text(operator.read_text().replace('shutil.copyfileobj(source, output)',
                        'shutil.copyfileobj(source, output)\n                    os.kill(os.getpid(), signal.SIGKILL)'))
                elif scenario == 'asset-remnant':
                    (root / 'releases' / f'chronicle-selfhost-{latest}.tar.gz').write_bytes(b'partial archive')
                keys = (root / "fixture-signing-key", root / "other-signing-key")
                for key in keys:
                    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                                   check=True, capture_output=True)
                shutil.copy2(str(keys[0]) + ".pub", selfhost / "release-signing.pub")
                key = keys[scenario == "foreign-signature"]
                checksum = root / "http" / f"chronicle-selfhost-{latest}.tar.gz.sha256"
                subprocess.run(["ssh-keygen", "-Y", "sign", "-n", RELEASE_SIGNER, "-f",
                                str(key), str(checksum)], check=True, capture_output=True)
                signature = checksum.with_name(checksum.name + ".sig")
                if scenario == "missing-signature":
                    metadata_path = root / "http/latest.json"
                    metadata = json.loads(metadata_path.read_text())
                    metadata["assets"] = [a for a in metadata["assets"] if a["name"] != signature.name]
                    metadata_path.write_text(json.dumps(metadata))
                if scenario == "tampered-checksum":
                    checksum.write_text("0" * 64 + "  " + checksum.name.removesuffix(".sha256") + "\n")
                elif scenario in ("missing-signature", "unavailable-signature"):
                    signature.unlink()
                elif scenario == "missing-installed-key":
                    (selfhost / "release-signing.pub").unlink()
                metadata_path = root / 'http/latest.json'
                metadata = json.loads(metadata_path.read_text())
                metadata['body'] = 'UNVERIFIED_RUN_THIS_SENTINEL\x1b[2J'
                metadata_path.write_text(json.dumps(metadata))
                environment.update(DOCKER_FIXTURE_ROOT=str(root), MIN_FREE_DISK_GIB="0")
                result = subprocess.run(["bash", str(selfhost / "chronicle"), "update", *arguments],
                                        env=environment, capture_output=True)
                self.assertEqual(result.returncode, expected_status, result.stderr.decode())
                self.assertNotIn(b'UNVERIFIED_RUN_THIS_SENTINEL', result.stdout + result.stderr)
                self.assertNotIn(b'\x1b[2J', result.stdout + result.stderr)
                self.assertEqual(list(release.rglob("__pycache__")), [])
                if expected_status == 137:
                    self.assertFalse((root / 'releases' / f'chronicle-selfhost-{latest}').exists())
                    self.assertEqual(list((root / 'releases').glob('*.tar.gz*')), [])
                    environment.pop('KILL_DOWNLOAD', None)
                    shutil.copy2(ROOT / 'selfhost/chronicle', selfhost / 'chronicle')
                    retry = subprocess.run(['bash', str(selfhost / 'chronicle'), 'update'],
                                           env=environment, capture_output=True, timeout=10)
                    self.assertEqual(retry.returncode, 0, retry.stderr.decode())
                    self.assertTrue((root / 'handoff').exists())
                elif expected_status == 1:
                    self.assertFalse((root / "releases" / f"chronicle-selfhost-{latest}").exists())
                    self.assertFalse((root / "handoff").exists())
                    self.assertIn("signature", result.stderr.decode())
                    self.assertEqual(list((root / "releases").glob("*.tar.gz*")), [])
                elif not arguments:
                    self.assertEqual((root / "handoff").read_text().splitlines()[1:],
                                     ["upgrade", "--from", str(selfhost)])
                    (root / "handoff").unlink()
                    retained_signature = root / "releases" / signature.name
                    retained_signature.write_text("tampered retained signature\n")
                    retry = subprocess.run(["bash", str(selfhost / "chronicle"), "update"],
                                           env=environment, capture_output=True)
                    self.assertEqual(retry.returncode, 1)
                    self.assertIn("invalid release signature", retry.stderr.decode())
                    self.assertFalse((root / "handoff").exists())

    def test_update_storage_uses_saved_project_floor_and_state_without_moving_bundle_origin(self):
        import io
        from types import SimpleNamespace
        code = update_code()
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder); release = root / 'releases/current'; host = release / 'selfhost'
            host.mkdir(parents=True); state = root / 'private-state'; state.mkdir()
            (release / 'release-manifest.json').write_text(json.dumps({'release_version': '1.2.3'}))
            (host / '.env').write_text(f"COMPOSE_PROJECT_NAME=study-production\nCHRONICLE_STATE_DIR='{state}'\nMIN_FREE_DISK_GIB=2\n")
            (host / '.env').chmod(0o600)
            (host / 'release-signing.pub').write_text('ssh-ed25519 synthetic-public-key\n')
            metadata = {'tag_name': 'v1.2.4', 'assets': [{'name': name, 'browser_download_url': 'https://fixture/' + name}
                for name in ('chronicle-selfhost-1.2.4.tar.gz', 'chronicle-selfhost-1.2.4.tar.gz.sha256', 'chronicle-selfhost-1.2.4.tar.gz.sha256.sig')]}
            with patch('sys.argv', ['update', str(host), '', 'https://fixture/latest']), \
                 patch('sys.stdout', io.StringIO()), patch('sys.stderr', io.StringIO()), \
                 patch('signal.signal'), patch('subprocess.run', return_value=SimpleNamespace(stdout=json.dumps(metadata))), \
                 patch('chronicle_ops.release.compose_projects', return_value=[]), \
                 patch('chronicle_ops.common.require_storage', side_effect=ValueError('stop before downloading')) as storage, \
                 self.assertRaises(SystemExit):
                exec(code, {'__name__': '__main__'})
            from chronicle_ops.common import UPDATE_PEAK_BYTES
            storage.assert_called_once_with(state, 'study-production', '2', UPDATE_PEAK_BYTES)

    def test_update_check_rejects_superseded_bundle_before_fetching_metadata(self):
        import io
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            root = Path(folder); host = root / 'retired/selfhost'; host.mkdir(parents=True)
            active = root / 'active'; active.mkdir()
            (host.parent / 'release-manifest.json').write_text(json.dumps({'release_version': '1.2.3'}))
            (host / '.env').write_text('COMPOSE_PROJECT_NAME=fixture\nCHRONICLE_STATE_DIR=.\n')
            (host / '.env').chmod(0o600)
            (host / 'reconcile.sh').write_text('cd ' + str(active) + '\n')
            with patch('sys.argv', ['update', str(host), '--check', 'https://fixture/latest']), \
                 patch('signal.signal'), patch('chronicle_ops.release.compose_projects', return_value=[]), \
                 patch('subprocess.run') as network, patch('sys.stderr', io.StringIO()), \
                 self.assertRaises(SystemExit) as result:
                exec(update_code(), {'__name__': '__main__'})
            self.assertIn('superseded', str(result.exception))
            network.assert_not_called()

    def test_release_signing_caddy_and_backup_sbom_regressions(self):
        import runpy
        checks = runpy.run_path(str(ROOT / "tests/security/selfhost-monitoring.py"))
        for name in ("test_release_signatures", "test_caddy_default_log_masks_handler_ips",
                     "test_mobile_snat_abuse_limits", "test_backup_sbom_inventory"):
            with self.subTest(check=name):
                checks[name]()

    def test_smoke_predecessor_and_bundle_fixtures_use_changelog_versions(self):
        source = (ROOT / "tests/smoke/selfhost-release-smoke.sh").read_text()
        start = source.index("latest_changelog_version() {")
        function = source[start:source.index("\n}\n", start) + 3]
        self.assertIn('OLD_VERSION="$(latest_changelog_version 1)"', source)
        selected = subprocess.run(["bash", "-c", 'ROOT_DIR="$1"\n' + function +
                                   "latest_changelog_version\nlatest_changelog_version 1\n",
                                   "fixture", str(ROOT)], check=True, capture_output=True, text=True).stdout.splitlines()
        import runpy
        builder = runpy.run_path(str(ROOT / "scripts/build-selfhost-release.py"))
        self.assertGreater(builder["parse_version"](selected[0], "fixture"),
                           builder["parse_version"](selected[1], "fixture"))
        fixture = (ROOT / "tests/security/selfhost-release-bundle.sh").read_text()
        version = next(line.split("=", 1)[1] for line in fixture.splitlines()
                       if line.startswith("RELEASE_VERSION="))
        for target in (*selected, version):
            builder["require_changelog"](ROOT / "CHANGELOG.md", target)

    def test_package_sources_are_python_39_compatible(self):
        for path in (ROOT / "selfhost/chronicle_ops").glob("*.py"):
            with self.subTest(module=path.name):
                ast.parse(path.read_text(), feature_version=(3, 9))

    def test_explicit_release_file_list_includes_the_package(self):
        tree = ast.parse((ROOT / "scripts/build-selfhost-release.py").read_text())
        inventory = next(node.value for node in ast.walk(tree)
                         if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name)
                         and target.id == "root_files" for target in node.targets))
        files = set(ast.literal_eval(inventory))
        self.assertIn("release-signing.pub", files)
        self.assertTrue({"chronicle_ops/" + path.name for path in (ROOT / "selfhost/chronicle_ops").glob("*.py")} <= files)
