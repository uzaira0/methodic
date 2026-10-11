from pathlib import Path
import subprocess
import unittest


SELFHOST = Path(__file__).resolve().parents[2] / "selfhost"


class NetworkPolicyTests(unittest.TestCase):
    def test_shared_parser_preserves_public_and_private_address_policies(self):
        for address, public, private in (
            ("8.8.8.8", True, False), ("127.000.0.1", False, True),
            ("10.1.2.3", False, True), ("256.1.2.3", False, False),
            ("2001:4860:4860::8888", True, False), ("fd12::1234", False, True),
            ("::1", False, True), ("::", False, False),
            ("1:2:3:4:5:6:7:8", True, False), ("1:2:3:4:5:6:7", False, False),
            ("2001:::1234", False, False), ("2001:12345::1", False, False),
            ("::ffff:127.0.0.1", False, False),
        ):
            with self.subTest(address=address):
                result = subprocess.run(["bash", str(SELFHOST / "guard-config.sh"),
                                         "--validate-public-host", "[" + address + "]" if ":" in address else address],
                                        capture_output=True)
                self.assertEqual(result.returncode == 0, public)
                result = subprocess.run(["bash", "-c", 'source "$1"; specific_private_bind "$2"',
                                         "policy", str(SELFHOST / "network-policy.sh"), address], capture_output=True)
                self.assertEqual(result.returncode == 0, private)
