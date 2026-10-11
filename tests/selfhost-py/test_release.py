import os
from contextlib import ExitStack
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "selfhost"))
from chronicle_ops.release import compose_names, compose_release, free_disk_floor, merge_env, parse_version, read_manifest, require_current_owner
from chronicle_ops.receipts import OPERATOR_RECEIPTS_DIR


def complete_manifest_fixture(bundle):
    """Complete the small shell fixtures with the publisher's integrity contract."""
    import json
    import shutil
    from chronicle_ops.dump import file_sha256
    from chronicle_ops.release import read_env, value
    bundle = Path(bundle)
    manifest_path = bundle / 'release-manifest.json'
    version = json.loads(manifest_path.read_text())['release_version']
    host = bundle / 'selfhost'
    for name in ('restore.sh', 'upgrade.sh', 'network-subnet.py', 'rotate-secret.sh',
                 'docs/DEPLOYMENT-COMPATIBILITY.md', 'docs/SECRET-ROTATION.md', 'docs/UNINSTALL-DATA-DELETION.md'):
        target = host / name
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(Path(__file__).resolve().parents[2] / 'selfhost' / name, target)
    template = host / '.env.example'
    if not template.exists():
        template.write_text(f'RELEASE_VERSION={version}\n' + ''.join(
            f'{key}=fixture/{image}@sha256:' + 'a' * 64 + '\n' for key, image in (
                ('BACKEND_IMAGE', 'backend'), ('SELFHOST_FRONTEND_IMAGE', 'frontend'), ('CADDY_IMAGE', 'caddy'))))
    (host / 'docker-compose.yml').touch(exist_ok=True)
    settings = read_env(template)
    manifest = {'schema_version': 1, 'release_version': version, 'source_revision': 'a' * 40,
                'images': {image: value(settings, key) for image, key in (
                    ('backend', 'BACKEND_IMAGE'), ('frontend', 'SELFHOST_FRONTEND_IMAGE'), ('caddy', 'CADDY_IMAGE'))},
                'files': {path.relative_to(bundle).as_posix(): file_sha256(path)
                          for path in bundle.rglob('*') if path.is_file() and path != manifest_path}}
    manifest_path.write_text(json.dumps(manifest))
    for path in [bundle, *bundle.rglob('*')]:
        path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)


def complete_update_fixture(root, version):
    import hashlib
    import tarfile
    root = Path(root)
    name = 'chronicle-selfhost-' + version
    archive_path = root / 'http' / (name + '.tar.gz')
    with tempfile.TemporaryDirectory(dir=root) as folder:
        with tarfile.open(archive_path) as archive:
            archive.extractall(folder)
        bundle = Path(folder) / name
        complete_manifest_fixture(bundle)
        with tarfile.open(archive_path, 'w:gz') as archive:
            archive.add(bundle, arcname=name)
    archive_path.with_suffix('.gz.sha256').write_text(
        hashlib.sha256(archive_path.read_bytes()).hexdigest() + '  ' + archive_path.name + '\n')
    docker = root / 'bin/docker'
    inventory = '''if [[ "$1 ${2:-}" == 'compose ls' ]]; then printf '[]\\n'; fi\n'''
    if inventory not in docker.read_text():
        with docker.open('a') as output:
            output.write(inventory)


class ReleaseTests(unittest.TestCase):
    def test_free_disk_floor_prefers_env_file_then_environment_then_default(self):
        with patch.dict(os.environ, {'MIN_FREE_DISK_GIB': '0'}):
            self.assertEqual(free_disk_floor({'MIN_FREE_DISK_GIB': '2'}), '2')
            self.assertEqual(free_disk_floor({}), '0')
        with patch.dict(os.environ, clear=True):
            self.assertEqual(free_disk_floor({}), '5')

    def test_rollback_keeps_the_same_candidate_valid_and_archives_settings_privately(self):
        from chronicle_ops.restore import rollback
        for legacy in (False, True):
            with self.subTest(legacy=legacy), tempfile.TemporaryDirectory() as folder, ExitStack() as stack:
                root = Path(folder)
                old, candidate, state = root / "old/selfhost", root / "candidate/selfhost", root / "state"
                old.mkdir(parents=True); candidate.mkdir(parents=True); state.mkdir()
                if not legacy:
                    (old / "chronicle_ops").mkdir()
                    (old / "chronicle_ops/__main__.py").touch()
                (candidate.parent / "release-manifest.json").write_text('{"release_version":"2.0.0"}')
                (candidate / "chronicle").touch()
                complete_manifest_fixture(candidate.parent)
                settings = f"COMPOSE_PROJECT_NAME=pilot\nCHRONICLE_STATE_DIR={state}\n"
                for host in (old, candidate):
                    (host / ".env").write_text(settings)
                    (host / ".env").chmod(0o600)
                (old / ".env.example").write_text(settings)
                operation = stack.enter_context(patch("chronicle_ops.restore.Restore"))
                operation.return_value.execute.return_value = 0
                for name in ("chronicle_ops.restore.acquire_operation_lock", "chronicle_ops.restore.release_operation_lock",
                             "chronicle_ops.restore.compose", "chronicle_ops.restore.return_monitoring_volumes", "chronicle_ops.release.require_current_owner",
                             "chronicle_ops.release.merge_env", "chronicle_ops.release.set_current_owner",
                             "chronicle_ops.reconcile.install", "chronicle_ops.reconcile.uninstall"):
                    stack.enter_context(patch(name))
                stack.enter_context(patch("chronicle_ops.common.run", return_value=subprocess.CompletedProcess([], 0)))
                stack.enter_context(patch.object(Path, "cwd", return_value=candidate))
                stack.enter_context(patch.dict(os.environ, {}, clear=True))
                self.assertEqual(rollback(old, "/backups/fixture.sql.gz", "a" * 64, True), 0)
                self.assertFalse((candidate / ".env").exists())
                archives = list((state / OPERATOR_RECEIPTS_DIR).glob(".env.rollback-*"))
                self.assertEqual(len(archives), 1)
                self.assertEqual(archives[0].read_text(), settings)
                self.assertEqual(archives[0].stat().st_mode & 0o777, 0o600)
                self.assertEqual(archives[0].parent.stat().st_mode & 0o777, 0o700)
                # This is the exact candidate validation performed at the next upgrade's entry.
                self.assertEqual(read_manifest(candidate.parent / "release-manifest.json", True)[0]["release_version"], "2.0.0")
                (candidate / "unlisted").write_text("unexpected file")
                with self.assertRaisesRegex(ValueError, "unlisted files"):
                    read_manifest(candidate.parent / "release-manifest.json", True)

    def test_release_ownership_survives_disabled_reconciliation_and_uninstall(self):
        from chronicle_ops import reconcile, release
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            state = Path(folder); active = state / 'active'; retired = state / 'retired'
            with patch.dict(os.environ, {reconcile.ENABLED_ENV: 'false'}, clear=True), \
                 patch('chronicle_ops.release.compose_projects', return_value=[]), \
                 patch('chronicle_ops.reconcile.shutil.which', return_value=None):
                (state / 'reconcile.sh').write_text('cd ' + str(retired) + '\n')
                reconcile.install(active / 'chronicle', state, 'pilot')
                require_current_owner(active, state, 'pilot')
                reconcile.uninstall(state, 'pilot')
                self.assertFalse((state / 'reconcile.sh').exists())
                with self.assertRaisesRegex(ValueError, 'superseded'):
                    require_current_owner(retired, state, 'pilot')
                require_current_owner(active, state, 'pilot')
                # Rollback transfers ownership even with no schedule to update.
                reconcile.install(retired / 'chronicle', state, 'pilot', update_only=True)
                with self.assertRaisesRegex(ValueError, 'superseded'):
                    require_current_owner(active, state, 'pilot')
                require_current_owner(retired, state, 'pilot')
                self.assertEqual((state / release.OWNER_FILE).stat().st_mode & 0o777, 0o644)

    def test_superseded_release_cannot_mutate_live_project_or_state_owner(self):
        import json
        import shlex
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            state = Path(folder); old = state / 'old'; active = state / 'active'
            for path in (old, active): path.mkdir()
            with patch('chronicle_ops.release.run', return_value=subprocess.CompletedProcess([], 0,
                    json.dumps([{'Name': 'pilot', 'ConfigFiles': str(active / 'docker-compose.yml')}]))):
                with self.assertRaisesRegex(ValueError, 'does not own'):
                    require_current_owner(old, state, 'pilot')
                require_current_owner(active, state, 'pilot')
            for output in ('malformed', '{}'):
                with patch('chronicle_ops.release.run', return_value=subprocess.CompletedProcess([], 0, output)), \
                     self.assertRaises(ValueError):
                    require_current_owner(old, state, 'pilot')
            (state / 'reconcile.sh').write_text('cd ' + shlex.quote(str(active)) + '\n')
            with patch('chronicle_ops.release.run', return_value=subprocess.CompletedProcess([], 0, '[]')):
                with self.assertRaisesRegex(ValueError, 'superseded'):
                    require_current_owner(old, state, 'pilot')
                require_current_owner(active, state, 'pilot')

    def test_compose_isolates_inherited_controls_and_all_interpolation_inputs(self):
        inherited = {"COMPOSE_FILE": "poison", "COMPOSE_PROFILES": "restore", "BACKEND_IMAGE": "poison",
                     "OPTIONAL_SETTING": "poison", "DOCKER_HOST": "unix:///docker.sock"}
        with patch.dict(os.environ, inherited, clear=True), patch.object(Path, "is_file", return_value=True), \
             patch.object(Path, "is_symlink", return_value=False), \
             patch.object(Path, "read_text", return_value="# BACKEND_IMAGE=fixture\nvalue: ${OPTIONAL_SETTING:-}\n"), \
             patch("chronicle_ops.release.run", return_value=subprocess.CompletedProcess([], 0)) as run:
            compose_release(Path("/release"), "pilot", ["docker-compose.yml"], "up", "-d")
            self.assertEqual(run.call_args.args[0], ["docker", "compose", "--env-file", "/release/.env", "--project-name", "pilot", "-f", "/release/docker-compose.yml", "up", "-d"])
            environment = run.call_args.kwargs["env"]
            for key in inherited.keys() - {"DOCKER_HOST"}:
                self.assertNotIn(key, environment)
            self.assertEqual(environment["DOCKER_HOST"], inherited["DOCKER_HOST"])
            self.assertEqual(environment["CHRONICLE_HOST_UID"], str(os.getuid()))

    def test_compose_paths_reject_escape_duplicates_and_retired_modes(self):
        for text in ("../outside.yml", "docker-compose.yml:docker-compose.yml", "docker-compose.yml:overlays/mode-behind-proxy-public.yml", "docker-compose.yml::overlays/backups.yml"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                compose_names({"COMPOSE_FILE": text}, Path("/release"))

    def test_merge_keeps_operator_values_and_new_defaults_and_pins(self):
        old = {"PASSWORD": "'fixture'", "BACKEND_IMAGE": "old", "CUSTOM": "'keep me'"}
        template = "RELEASE_VERSION=2.0.0\nBACKEND_IMAGE=new\nPASSWORD=default\nCHRONICLE_STATE_DIR=.\nCOMPOSE_FILE=old\nNEW=default\n"
        with patch("chronicle_ops.release.write_text") as write:
            merge_env(old, template, Path("/new/.env"), "/operator's state", ["docker-compose.yml"])
            content = write.call_args.args[1]
            for line in ("PASSWORD='fixture'", "BACKEND_IMAGE=new", 'CHRONICLE_STATE_DIR="/operator\'s state"', "COMPOSE_FILE=docker-compose.yml", "CUSTOM='keep me'", "NEW=default"):
                self.assertIn(line + "\n", content)

    def test_merge_migrates_105_loopback_proxy_and_dashboard_without_lockout(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / 'selfhost/guard-config.sh').read_text()
        start = source.index('if [[ "$TLS_MODE" == behind-proxy ]] && loopback_networks')
        guard = source[start:source.index('\nfi', start) + len('\nfi')]
        template = 'CADDY_TRUSTED_PROXIES=172.28.0.1/32\nDASHBOARD_ALLOWED_IPS=default\n'
        for bind, pool, expected in (('127.0.0.1', '', '10.253.8.1/32'),
                                      ('10.0.0.5', '10.0.0.9/32', '10.0.0.9/32'),
                                      ('10.0.0.5', '', "'127.0.0.1/32 ::1/128'")):
            old = {'DASHBOARD_PASSWORD_HASH': "'$2b$fixture'", 'HTTP_BIND': bind, 'CHRONICLE_SUBNET': '10.253.8.0/24', 'POOL_ALLOWED_IPS': pool,
                   'CADDY_TRUSTED_PROXIES': "'127.0.0.1/32 ::1/128'", 'DASHBOARD_ALLOWED_IPS': "'127.0.0.1/32 ::1/128'"}
            with self.subTest(bind=bind), patch('sys.stdout'), patch('chronicle_ops.release.write_text') as write:
                merge_env(old, template, Path('/new/.env'), '/state', ['overlays/mode-behind-proxy-internal.yml'])
            script = 'source "$1"; bad() { exit 1; }; warn() { :; };\n' + write.call_args.args[1] + '\nTLS_MODE=behind-proxy\n' + guard
            subprocess.run(['bash', '-eu', '-c', script, 'fixture', str(root / 'selfhost/network-policy.sh')], check=True)
            self.assertIn('CADDY_TRUSTED_PROXIES=' + expected + '\n', write.call_args.args[1])
            self.assertIn("DASHBOARD_ALLOWED_IPS='10.253.8.1/32 127.0.0.1/32 ::1/128'", write.call_args.args[1])
        with patch('chronicle_ops.release.write_text') as write, self.assertRaisesRegex(ValueError, 'explicit non-loopback'):
            merge_env(dict(old, POOL_ALLOWED_IPS="'0.0.0.0/0 ::/0'"), template, Path('/new/.env'), '/state', ['overlays/mode-behind-proxy-internal.yml'])
        write.assert_not_called()

    def test_new_inventory_must_be_exact(self):
        import json
        files = {name: "a" * 64 for name in ("selfhost/.env.example", "selfhost/chronicle", "selfhost/docker-compose.yml", "selfhost/restore.sh", "selfhost/upgrade.sh", "selfhost/network-subnet.py", "selfhost/rotate-secret.sh", "selfhost/docs/DEPLOYMENT-COMPATIBILITY.md", "selfhost/docs/SECRET-ROTATION.md", "selfhost/docs/UNINSTALL-DATA-DELETION.md")}
        manifest = {"schema_version": 1, "release_version": "2.0.0", "source_revision": "a" * 40, "files": files}
        paths = [Path("/bundle") / name for name in files] + [Path("/bundle/unlisted")]
        with patch.object(Path, "is_file", return_value=True), patch.object(Path, "is_symlink", return_value=False), \
             patch.object(Path, "read_text", return_value=json.dumps(manifest)), \
             patch.object(Path, "rglob", return_value=paths), patch("chronicle_ops.release.file_sha256", return_value="a" * 64):
            with self.assertRaisesRegex(ValueError, "new release file inventory is not exact"):
                read_manifest(Path("/bundle/release-manifest.json"), True)

    def test_semver_ordering_and_numeric_prerelease(self):
        versions = ["1.0.0-alpha.2", "1.0.0-alpha.10", "1.0.0", "1.0.1"]
        self.assertEqual(sorted(versions, key=lambda version: parse_version(version, "fixture")), versions)
        with self.assertRaises(ValueError):
            parse_version("1.0.0-01", "fixture")
