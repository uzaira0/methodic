from pathlib import Path
import os
import subprocess
import unittest


class ProbeTests(unittest.TestCase):
    def test_served_certificates_require_trust_identity_and_convert_expiry(self):
        source = (Path(__file__).resolve().parents[2] / "selfhost/monitoring/probe.sh").read_text()
        functions = source[source.index("certificate_expiry() {"):source.index("collect() {")]
        stubs = '''
DOMAIN=configured
timeout() { shift; "$@"; }
openssl() {
  if [[ "$1" == s_client ]]; then
    shift
    [[ "$*" == "$EXPECTED_CONNECT" ]] || return 1
    printf 'served\\n'
  else
    read -r certificate
    [[ "$certificate" == served ]] || return 1
    printf 'notAfter=PUBLIC_EXPIRY\\n'
  fi
}
date() {
  case "$2" in
    PUBLIC_EXPIRY) printf 1900000000 ;;
    *) return 1 ;;
  esac
}
'''
        for url, connect in (
            ("https://host.test/path?q=1#fragment", "host.test:443 -servername host.test"),
            ("https://host.test:8443/study", "host.test:8443 -servername host.test"),
            ("https://192.168.0.1", "192.168.0.1:443 -noservername"),
            ("https://[fd00::1]", "[fd00::1]:443 -noservername"),
            ("https://[fd00::1]:8443", "[fd00::1]:8443 -noservername"),
        ):
            with self.subTest(url=url):
                script = functions + stubs + 'EXPECTED_CONNECT="$2"; public_tls_expiry "$1"'
                result = subprocess.run(["bash", "-c", script, "probe", url, "-verify_return_error -connect " + connect + (" -verify_ip " if " -noservername" in connect else " -verify_hostname ") + ("fd00::1" if "fd00" in url else "192.168.0.1" if "192.168" in url else "host.test")],
                                        capture_output=True, text=True, check=True)
                self.assertEqual(result.stdout, "1900000000")
        for command, expected in (("certificate_expiry </dev/null", "0"),
                                  ("public_tls_expiry http://host.test", "0"),
                                  ("DOMAIN=unknown; public_tls_expiry https://host.test", "0")):
            with self.subTest(command=command):
                result = subprocess.run(["bash", "-c", functions + stubs + command],
                                        capture_output=True, text=True, check=True)
                self.assertEqual(result.stdout, expected)
        expected = '-verify_return_error -connect web:8081 -servername management.example.org -verify_hostname management.example.org -partial_chain -CAfile retained.crt'
        script = functions + stubs + 'EXPECTED_CONNECT="$1"; public_tls_expiry https://management.example.org:8443 retained.crt web:8081'
        result = subprocess.run(['bash', '-c', script, 'probe', expected], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, '1900000000')

    def test_management_probe_keeps_configured_identity_and_maps_container_port(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / 'selfhost/monitoring/probe.sh').read_text()
        start = source.index('read -r INTERNAL_TLS_URL')
        end = source.index('\n\n[[ "$PROBE_INTERVAL_SECONDS"', start)
        script = source[start:end] + '\nprintf "%s\\n%s" "$INTERNAL_HEALTH_URL" "$INTERNAL_CONNECT"'
        for settings, expected in (({'DASHBOARD_BASE_URL': 'https://management.example.org:8443'},
                                    'https://management.example.org:8443/health\nmanagement.example.org:8443:web:8081'),
                                   ({'INTERNAL_BIND': 'fd42::1', 'INTERNAL_PORT': '8443'},
                                    'https://[fd42::1]:8443/health\n[fd42::1]:8443:web:8081')):
            environment = {key: value for key, value in os.environ.items()
                           if key not in ('DASHBOARD_BASE_URL', 'INTERNAL_BIND', 'INTERNAL_PORT', 'INTERNAL_HEALTH_URL')}
            result = subprocess.run(['bash', '-eu', '-c', script], env=dict(environment, **settings,
                                    PYTHONPATH=str(root / 'selfhost')), capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout, expected)
