#!/usr/bin/env bash
# Live SSO smoke tests for the deployed BCM Keycloak broker.
set -euo pipefail

BASE_URL="${1:-http://10.23.4.137}"
HOST_HEADER="${2:-chronicle-screentime-app.research.bcm.edu}"
# Which broker the deployment defaults to (must match KEYCLOAK_DEFAULT_IDP /
# OIDC_IDP_HINT in the running .env). bcm-oidc once BCM's OIDC OP is live; bcm
# while on the SAML fallback. The SP-descriptor + explicit kc_idp_hint=bcm SAML
# assertions below always target the bcm broker regardless.
EXPECTED_IDP="${3:-${EXPECTED_DEFAULT_IDP:-bcm-oidc}}"
WORK_DIR="${TMPDIR:-/tmp}/chronicle-sso-live-smoke"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

curl_host() {
  curl -sS -H "Host: ${HOST_HEADER}" "$@"
}

descriptor_url="${BASE_URL}/keycloak/realms/chronicle/broker/bcm/endpoint/descriptor"
curl_host -D "$WORK_DIR/descriptor.headers" -o "$WORK_DIR/descriptor.xml" "$descriptor_url"

python3 - "$WORK_DIR/descriptor.headers" "$WORK_DIR/descriptor.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

headers = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
root = ET.parse(sys.argv[2]).getroot()
ns = {
    "md": "urn:oasis:names:tc:SAML:2.0:metadata",
    "ds": "http://www.w3.org/2000/09/xmldsig#",
}
sp = root.find(".//md:SPSSODescriptor", ns)
if "HTTP/1.1 200" not in headers and "HTTP/2 200" not in headers:
    raise SystemExit("SP metadata endpoint did not return 200")
if root.attrib.get("entityID") != "https://chronicle-screentime-app.research.bcm.edu/keycloak/realms/chronicle":
    raise SystemExit("Unexpected SAML entityID")
if sp is None:
    raise SystemExit("SPSSODescriptor missing")
if sp.attrib.get("AuthnRequestsSigned") != "true":
    raise SystemExit("AuthnRequestsSigned must be true")
if sp.attrib.get("WantAssertionsSigned") != "true":
    raise SystemExit("WantAssertionsSigned must be true")
if root.find("ds:Signature", ns) is None:
    raise SystemExit("SP metadata must be signed")
if not sp.findall("md:KeyDescriptor", ns):
    raise SystemExit("SP signing key descriptor missing")
locations = {
    acs.attrib.get("Location")
    for acs in root.findall(".//md:AssertionConsumerService", ns)
}
expected = "https://chronicle-screentime-app.research.bcm.edu/keycloak/realms/chronicle/broker/bcm/endpoint"
if expected not in locations:
    raise SystemExit("Expected ACS endpoint missing")
required_headers = [
    "Strict-Transport-Security:",
    "X-Content-Type-Options: nosniff",
    "X-Frame-Options: DENY",
    "Referrer-Policy: strict-origin-when-cross-origin",
]
for header in required_headers:
    if header.lower() not in headers.lower():
        raise SystemExit(f"Missing security header: {header}")
PY

chronicle_login_url="${BASE_URL}/chronicle/v3/auth/oidc/login"
curl_host -D "$WORK_DIR/chronicle-login.headers" -o "$WORK_DIR/chronicle-login.body" "$chronicle_login_url" >/dev/null

python3 - "$WORK_DIR/chronicle-login.headers" "$EXPECTED_IDP" <<'PY'
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

headers = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
expected_idp = sys.argv[2]
status = next((line for line in headers if line.startswith("HTTP/")), "")
if "302" not in status and "303" not in status:
    raise SystemExit(f"Expected Chronicle OIDC login redirect, got {status}")
location = next((line.split(":", 1)[1].strip() for line in headers if line.lower().startswith("location:")), "")
parsed = urlparse(location)
query = parse_qs(parsed.query)
if parsed.path != "/keycloak/realms/chronicle/protocol/openid-connect/auth":
    raise SystemExit(f"Unexpected Chronicle OIDC auth path: {parsed.path}")
if query.get("kc_idp_hint") != [expected_idp]:
    raise SystemExit(f"Chronicle OIDC login must force the {expected_idp} identity provider hint, got {query.get('kc_idp_hint')}")
PY

auth_url_no_hint="${BASE_URL}/keycloak/realms/chronicle/protocol/openid-connect/auth?client_id=chronicle-web&redirect_uri=https%3A%2F%2Fchronicle-screentime-app.research.bcm.edu%2Fchronicle%2Fv3%2Fauth%2Foidc%2Fcallback&response_type=code&scope=openid&code_challenge=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk&code_challenge_method=S256"
curl_host -D "$WORK_DIR/no-hint.headers" -o "$WORK_DIR/no-hint.body" "$auth_url_no_hint" >/dev/null

python3 - "$WORK_DIR/no-hint.headers" "$WORK_DIR/no-hint.body" "$EXPECTED_IDP" <<'PY'
import sys
from pathlib import Path
from urllib.parse import urlparse

headers = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
body = Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace")
expected_idp = sys.argv[3]
status = next((line for line in headers if line.startswith("HTTP/")), "")
if "302" not in status and "303" not in status:
    raise SystemExit(f"Expected default BCM broker redirect without kc_idp_hint, got {status}")
location = next((line.split(":", 1)[1].strip() for line in headers if line.lower().startswith("location:")), "")
parsed = urlparse(location)
# Default broker is redirector-driven (KEYCLOAK_DEFAULT_IDP / EXPECTED_DEFAULT_IDP);
# the other broker remains a selectable fallback. The explicit kc_idp_hint=bcm SAML
# path below always exercises the SAML broker end-to-end regardless of the default.
expected_path = f"/keycloak/realms/chronicle/broker/{expected_idp}/login"
if parsed.path != expected_path:
    raise SystemExit(f"Auth without kc_idp_hint must redirect to {expected_idp} broker ({expected_path}), got {parsed.path}")
if "type=\"password\"" in body or "type='password'" in body:
    raise SystemExit("Auth without kc_idp_hint must not render a local password form")
PY

# Explicit kc_idp_hint=bcm exercises the SAML fallback broker end-to-end (through
# to fedidp.bcm.edu with a SAMLRequest). The OIDC OP default cannot be smoke-tested
# end-to-end until BCM provisions and exposes it; the broker-login redirect above
# is the deepest assertion possible without the live upstream OP.
auth_url="${BASE_URL}/keycloak/realms/chronicle/protocol/openid-connect/auth?client_id=chronicle-web&redirect_uri=https%3A%2F%2Fchronicle-screentime-app.research.bcm.edu%2Fchronicle%2Fv3%2Fauth%2Foidc%2Fcallback&response_type=code&scope=openid&code_challenge=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk&code_challenge_method=S256&kc_idp_hint=bcm"
curl_host -D "$WORK_DIR/step1.headers" -o "$WORK_DIR/step1.body" "$auth_url" >/dev/null

python3 - "$WORK_DIR/step1.headers" "$WORK_DIR/step2.url" "$WORK_DIR/cookies.txt" "$BASE_URL" <<'PY'
import sys
from pathlib import Path
from urllib.parse import urlparse

headers = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
base_url = sys.argv[4].rstrip("/")
status = next((line for line in headers if line.startswith("HTTP/")), "")
if "303" not in status and "302" not in status:
    raise SystemExit(f"Expected Keycloak broker redirect, got {status}")
location = next((line.split(":", 1)[1].strip() for line in headers if line.lower().startswith("location:")), "")
parsed = urlparse(location)
if parsed.path != "/keycloak/realms/chronicle/broker/bcm/login":
    raise SystemExit(f"Unexpected broker redirect path: {parsed.path}")
cookies = [
    line.split(":", 1)[1].strip().split(";", 1)[0]
    for line in headers
    if line.lower().startswith("set-cookie:")
]
if not cookies:
    raise SystemExit("Broker redirect did not set auth cookies")
Path(sys.argv[2]).write_text(base_url + parsed.path + ("?" + parsed.query if parsed.query else ""), encoding="utf-8")
Path(sys.argv[3]).write_text("; ".join(cookies), encoding="utf-8")
PY

curl_host \
  -H "Cookie: $(cat "$WORK_DIR/cookies.txt")" \
  -D "$WORK_DIR/step2.headers" \
  -o "$WORK_DIR/step2.body" \
  "$(cat "$WORK_DIR/step2.url")" >/dev/null

python3 - "$WORK_DIR/step2.headers" <<'PY'
import sys
from pathlib import Path
from urllib.parse import urlparse

headers = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
status = next((line for line in headers if line.startswith("HTTP/")), "")
if "302" not in status and "303" not in status:
    raise SystemExit(f"Expected SAML IdP redirect, got {status}")
location = next((line.split(":", 1)[1].strip() for line in headers if line.lower().startswith("location:")), "")
parsed = urlparse(location)
if parsed.netloc != "fedidp.bcm.edu":
    raise SystemExit(f"Unexpected IdP host: {parsed.netloc}")
if parsed.path != "/idp/profile/SAML2/Redirect/SSO":
    raise SystemExit(f"Unexpected IdP path: {parsed.path}")
if "SAMLRequest=" not in location:
    raise SystemExit("BCM redirect is missing SAMLRequest")
PY

echo "Live SSO smoke tests passed"
