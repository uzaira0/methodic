import gzip
import io
import re
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "selfhost"))
from chronicle_ops.verify import verify_backup, curl_config
from test_restore import DUMP


class VerifyBackupTests(unittest.TestCase):
    def test_restored_privileges_are_checked_and_operator_dumps_keep_acls(self):
        from types import SimpleNamespace
        from chronicle_ops.release import ROLLBACK_DUMP
        from chronicle_ops.verify import DATABASE_PRIVILEGES_SQL, verify_database_privileges
        for answer in ('t', 'f', '', 'malformed'):
            with patch('chronicle_ops.verify.compose', return_value=SimpleNamespace(stdout='postgres-id')), \
                 patch('chronicle_ops.verify.postgres_sql', return_value=answer) as query:
                if answer == 't': verify_database_privileges()
                else:
                    with self.assertRaisesRegex(ValueError, 'least privilege'): verify_database_privileges()
                query.assert_called_once_with('postgres-id', DATABASE_PRIVILEGES_SQL)
        self.assertNotIn('--no-privileges', ROLLBACK_DUMP)
        root = Path(__file__).resolve().parents[2]
        for name in ('restore.sh', 'rotate-secret.sh'):
            self.assertNotIn('--no-privileges', (root / 'selfhost' / name).read_text())
        restore = (root / 'selfhost/restore.sh').read_text()
        self.assertIn('from chronicle_ops.verify import DATABASE_PRIVILEGES_SQL', restore)
        self.assertIn('IF NOT ($DATABASE_PRIVILEGES_SQL)', restore)
        self.assertIn('ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM chronicle_app, chronicle_admin;', restore)

    def check(self, contents):
        files = {Path(f"/backups/last/{i}.sql.gz"): data for i, data in enumerate(contents)}
        opened = []
        def stream(path, _mode):
            opened.append(path)
            return gzip.GzipFile(fileobj=io.BytesIO(files[path]))
        output = io.StringIO()
        with patch.object(Path, "glob", return_value=reversed(list(files))), \
             patch("chronicle_ops.dump.gzip.open", stream), patch("sys.stdout", output):
            status = verify_backup("/backups")
        return status, output.getvalue(), opened

    def test_no_backup_retains_exact_message(self):
        status, output, opened = self.check([])
        self.assertEqual(status, 1)
        self.assertEqual(output, "  \033[31mFAIL\033[0m no SQL dump yet — nothing recoverable if the keyring is lost\n")
        self.assertEqual(opened, [])

    def test_complete_dump_retains_exact_success(self):
        status, output, _ = self.check([gzip.compress(DUMP)])
        self.assertEqual(status, 0)
        self.assertEqual(output, "  \033[32mok\033[0m   a key-free SQL dump exists (restores without pg_tde)\n")

    def test_normal_pg_dump_footer_needs_no_rewriting(self):
        dump = DUMP.replace(b"\\unrestrict fixture\n-- PostgreSQL database dump complete\n",
                            b"-- PostgreSQL database dump complete\n\n--\n\n\\unrestrict fixture\n")
        self.assertEqual(self.check([gzip.compress(dump)])[0], 0)

    def test_b5_rejects_invalid_gzip_and_truncated_crc(self):
        for content in (b"fixture-dump\n", gzip.compress(DUMP)[:-3]):
            with self.subTest(content=content):
                status, output, _ = self.check([content])
                self.assertEqual(status, 1)
                self.assertIn("SQL dump failed gzip integrity verification", output)

    def test_b5_rejects_incomplete_empty_or_nonfinal_marker(self):
        for content in (DUMP.replace(b"-- PostgreSQL database dump complete\n", b""), b"", DUMP + b"SELECT 2;\n",
                        DUMP.replace(b"-- PostgreSQL database dump complete\n", b"-- PostgreSQL database dump complete\r\n")):
            with self.subTest(content=content):
                status, output, _ = self.check([gzip.compress(content)])
                self.assertEqual(status, 1)
                self.assertIn("lacks the final PostgreSQL database dump complete marker", output)

    def test_read_failure_is_indeterminate(self):
        with patch.object(Path, "glob", return_value=[Path("unreadable.sql.gz")]), \
             patch("chronicle_ops.dump.gzip.open", side_effect=PermissionError()), patch("sys.stdout", io.StringIO()):
            self.assertEqual(verify_backup("/backups"), 1)

    def test_all_candidates_are_checked_in_stable_order(self):
        complete = gzip.compress(DUMP)
        status, _, opened = self.check([complete, complete])
        self.assertEqual(status, 0)
        self.assertEqual(opened, [Path("/backups/last/0.sql.gz"), Path("/backups/last/1.sql.gz")])
        status, output, _ = self.check([complete, b"bad"])
        self.assertEqual(status, 1)
        self.assertIn("/backups/last/1.sql.gz", output)

    def test_credentials_are_curl_config_escaped_and_line_breaks_rejected(self):
        self.assertEqual(curl_config("user", 'researcher:one"two\\three'),
                         'user = "researcher:one\\"two\\\\three"\n')
        for value in ("one\ntwo", "one\rtwo"):
            with self.assertRaises(ValueError):
                curl_config("user", value)


class VerifyCredentialsTests(unittest.TestCase):
    def test_verify_rejects_changed_lock_identity_before_probing(self):
        import os
        from chronicle_ops.verify import verify
        environment = {"CHRONICLE_OPS_STATE": "/state", "CHRONICLE_OPS_PROJECT": "pilot"}
        for settings in ({"CHRONICLE_STATE_DIR": "/other", "COMPOSE_PROJECT_NAME": "pilot"},
                         {"CHRONICLE_STATE_DIR": "/state", "COMPOSE_PROJECT_NAME": "other"}):
            with self.subTest(settings=settings), patch.dict(os.environ, environment, clear=True), \
                 patch("chronicle_ops.verify.read_env", return_value=settings), \
                 patch("chronicle_ops.verify.curl") as curl, self.assertRaisesRegex(ValueError, "changed"):
                verify([])
            curl.assert_not_called()

    def test_rate_limit_guardrail_and_documented_settings_match_caddy(self):
        import os
        import subprocess
        import tempfile
        from chronicle_ops.release import read_env, value
        root = Path(__file__).resolve().parents[2]
        settings = read_env(root / "selfhost/.env.example")
        readme = (root / "selfhost/README.md").read_text()
        zones = re.findall(r"events \{\$(RATE_LIMIT_(?:MOBILE|WEB)_ABUSE_EVENTS):(\d+)\}",
                           (root / "selfhost/caddy/snippets.caddy").read_text())
        self.assertEqual(len(zones), 2)
        for key, default in zones:
            self.assertEqual(value(settings, key), default)
            self.assertIn(key, readme)
        compose = (root / "selfhost/docker-compose.yml").read_text()
        self.assertIsNone(re.search(r"RATE_LIMIT_(?:MOBILE|WEB)_EVENTS", readme + str(settings) + compose))
        source = (root / "tests/security/selfhost-verify-secrets.sh").read_text()
        guard = source.split('/bin/chmod 0755 "${FIXTURE_SELFHOST}/chronicle"\n', 1)[1].split('\nPASSWORD=', 1)[0]
        result = subprocess.run(["bash", "-eu", "-c", 'fail() { echo "$*" >&2; exit 1; };\n' + guard],
                                env=dict(os.environ, ROOT_DIR=str(root)), capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as folder:
            result = subprocess.run(["bash", str(root / "tests/security/selfhost-verify-secrets.sh")],
                env=dict(os.environ, SELFHOST_VERIFY_TEST_ROOT=str(Path(folder) / "runs")),
                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_real_verify_keeps_credentials_in_stdin_and_proves_session(self):
        import os
        from types import SimpleNamespace
        from chronicle_ops.verify import verify
        password, postgres, reviewer = "dashboard-sentinel", "postgres-sentinel", "reviewer-sentinel"
        settings = {"DOMAIN": "example.test", "POSTGRES_PASSWORD": postgres,
                    "HTTP_BIND": "10.0.0.5", "CADDY_TRUSTED_PROXIES": "127.0.0.1/32",
                    "CHRONICLE_REVIEWER_ACCESS_ENABLED": "true", "CHRONICLE_REVIEWER_ACCESS_SECRET": reviewer,
                    "RATE_LIMIT_RETRY_SLEEP": "0"}
        # F5 SNAT admits this whole probe at the edge. A fresh backend default bucket
        # must be exhausted instead; derive its capacity from the shipped configuration.
        config = (Path(__file__).resolve().parents[2] / "chronicle-server/src/main/resources/rate-limit.yaml").read_text()
        capacity = int(int(re.search(r"^default-requests-per-minute: (\d+)$", config, re.M)[1]) *
                       float(re.search(r"^burst-capacity-multiplier: ([\d.]+)$", config, re.M)[1]))
        calls = []
        uploads = 0
        def command(args, **kwargs):
            nonlocal uploads
            self.assertTrue(all(secret not in " ".join(args) for secret in (password, postgres, reviewer)))
            for key in ("DASHBOARD_PASSWORD", "POSTGRES_PASSWORD", "CHRONICLE_REVIEWER_ACCESS_SECRET"):
                self.assertNotIn(key, os.environ)
            calls.append((args, kwargs))
            url = args[-1]
            code = "404"
            if url.endswith("/health"):
                code = "204"
            if url.endswith(("/chronicle", "/chronicle/", "/chronicle/survey")):
                code = "200"
            if url.startswith("https://" + bind + ":") and url.endswith("/chronicle/api/web/study"):
                code = "403" if denied else "401"
            if url.endswith("/chronicle/study/x"):
                code = "401"
            if "participant/reviewer/enroll" in url:
                code = "401"
            if url.endswith("/chronicle/v4/mobile/reviewer-enrollment"):
                code = "200" if reviewer in (kwargs.get("input") or "") else "401"
            if url.endswith("/chronicle/v4/study/x/upload"):
                uploads += 1
                code = "401" if uploads <= capacity else "429"
            if url.endswith("/chronicle/v3/auth/dashboard-login"):
                self.assertIn('data-binary = ', kwargs["input"])
                code = "200" if password in kwargs["input"] else "401"
            if url.endswith("/chronicle/v3/auth/session") and "--cookie" in args:
                code = "200"
            output = code
            if "-sI" in args:
                output = "WWW-Authenticate: Basic realm=chronicle\r\n"
            if "--cookie" in args or "--cookie-jar" in args:
                # Like the backend, each answer sets a fresh CSRF cookie and returns that token.
                csrf = "fixture-" + url.rsplit("/", 1)[1]
                if "--cookie-jar" in args:
                    Path(args[args.index("--cookie-jar") + 1]).write_text(
                        "# Netscape HTTP Cookie File\n127.0.0.1\tFALSE\t/chronicle\tTRUE\t0\tol_csrf_token\t" + csrf + "\n")
                output = '{"authenticated": ' + str(code == '200').lower() + ', "csrfToken": "' + csrf + '"}\n' + code
            elif "-w" in args:
                fmt = args[args.index("-w") + 1]
                if "url_effective" in fmt:
                    output = f"200|{url.rsplit('/', 1)[0]}/chronicle/reviewer|128"
                elif "size_download" in fmt:
                    output = code + " 128"
            if url == "http://example.test/health":
                output = "HTTP/1.1 308\r\nLocation: https://example.test/health\r\n\r\n\n308"
            return SimpleNamespace(returncode=0, stdout=output)
        def database(*args, **kwargs):
            if "postgres" in args:
                self.assertTrue(kwargs["input"].startswith(postgres + "\0"))
                return SimpleNamespace(returncode=0, stdout="0" if "<>" in kwargs["input"] else "7")
            return SimpleNamespace(returncode=0, stdout="")
        environment = {"DASHBOARD_PASSWORD": password,
                       "CHRONICLE_OPS_TLS_MODE": "own-tls", "CHRONICLE_OPS_EXPOSURE": "internal",
                       "CHRONICLE_OPS_BACKUPS": "/backups", "DOMAIN": "stale.test",
                       "CHRONICLE_PUBLIC_BASE_URL": "https://stale.test", "ENABLE_ENCRYPTION": "false",
                       "COMPOSE_FILE": "docker-compose.yml"}
        for mode, bind, denied, expected in (("own-tls", "127.0.0.1", False, 0),
                                           ("behind-proxy", "127.0.0.1", False, 0),
                                           ("own-tls", "127.0.0.1", True, 1),
                                           ("own-tls", "10.0.0.5", True, 0)):
            environment["CHRONICLE_OPS_TLS_MODE"] = mode
            settings["INTERNAL_BIND"] = bind
            settings["COMPOSE_FILE"] = f"docker-compose.yml:overlays/mode-{mode}-internal.yml:overlays/backups.yml"
            calls.clear()
            uploads = 0
            with self.subTest(mode=mode), patch.dict(os.environ, environment, clear=True), \
                 patch("chronicle_ops.verify.read_env", return_value=settings), \
                 patch("chronicle_ops.verify.dashboard_ca", return_value=Path("/tls/internal-cert.pem")), \
                 patch("chronicle_ops.verify.run", side_effect=command), patch("chronicle_ops.verify.compose", side_effect=database), \
                 patch("chronicle_ops.verify.verify_backup", return_value=0), \
                 patch("chronicle_ops.verify.verify_database_privileges"), \
                 patch("chronicle_ops.verify.verify_backup_storage", return_value=1), patch("chronicle_ops.verify.time.sleep"), \
                 patch.object(Path, "is_dir", return_value=True), patch.object(Path, "is_file", return_value=True), \
                 patch.object(Path, "iterdir", return_value=[]), patch("chronicle_ops.verify.os.access", return_value=True), patch.object(Path, "stat", return_value=SimpleNamespace(st_mode=0o700, st_size=1)), \
                 patch("sys.stdout", new_callable=io.StringIO) as output:
                self.assertEqual(verify([]), expected, output.getvalue())
                self.assertGreater(uploads, capacity)
                self.assertIn("Encryption at rest", output.getvalue())
                self.assertEqual(os.environ["COMPOSE_FILE"], settings["COMPOSE_FILE"])
                self.assertNotIn(password, output.getvalue())
                if not denied:
                    self.assertIn("backend issued an authenticated dashboard session", output.getvalue())
                authenticated = [kwargs["input"] for _, kwargs in calls if password in (kwargs.get("input") or "")]
                self.assertEqual(len(authenticated), 0 if denied and bind != "127.0.0.1" else 1)
                self.assertNotIn("tests/deployment/", output.getvalue())
                if mode == "behind-proxy":
                    self.assertIn("Public HTTPS passed from this host", output.getvalue())
                    self.assertTrue(any(args[-1] == "https://example.test/health" for args, _ in calls))



class RedirectTests(unittest.TestCase):
    def test_exact_redirect_target_status_and_deadlines(self):
        from types import SimpleNamespace
        from chronicle_ops.verify import check_proxy_http_redirect
        expected = "https://example.test/health"
        for code, location, result in (("308", expected, "308"), ("301", "https://other.test/health", None), ("200", expected, None)):
            with self.subTest(code=code, location=location), \
                 patch("chronicle_ops.verify.run", return_value=SimpleNamespace(returncode=0, stdout=f"HTTP/1.1 {code}\r\nLocation: {location}\r\n\r\n\n{code}")) as call:
                self.assertEqual(check_proxy_http_redirect("http://example.test/health", expected), result)
                args = call.call_args.args[0]
                self.assertEqual(args[args.index("--connect-timeout") + 1], "5")
                self.assertEqual(args[args.index("--max-time") + 1], "10")
                self.assertNotIn("-L", args)
                self.assertNotIn("--location", args)
        with patch("chronicle_ops.verify.run", return_value=SimpleNamespace(returncode=28, stdout=f"Location: {expected}\n308")):
            self.assertIsNone(check_proxy_http_redirect("http://example.test/health", expected))
