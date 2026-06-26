#!/usr/bin/env bash
# Probe BCM's Shibboleth OIDC OP discovery document to confirm the OP is live and
# capture the REAL endpoints for the `bcm-oidc` Keycloak broker (BCM_OIDC_* in .env).
#
# Shibboleth IdP 4/5 with the OIDC OP plugin publishes an OpenID discovery doc at
# <issuer>/.well-known/openid-configuration. This script fetches it, verifies it is
# a usable OIDC OP, reports the amr/MFA signal, and prints a paste-ready BCM_OIDC_*
# block on stdout (human-readable summary goes to stderr, so you can redirect just
# the env block:  docker/keycloak/probe-bcm-oidc.sh > /tmp/bcm-oidc.env ).
#
# Usage:
#   docker/keycloak/probe-bcm-oidc.sh [DISCOVERY_URL]
# Default DISCOVERY_URL: https://fedidp.bcm.edu/.well-known/openid-configuration
# (run from a host inside BCM's network — fedidp.bcm.edu is an internal federation IdP)
#
# Exit codes:
#   0  OP is live and exposes the endpoints the broker needs
#   2  discovery document unreachable or not valid OIDC JSON
#   3  reachable but missing endpoints the broker requires
set -euo pipefail

DISCOVERY_URL="${1:-https://fedidp.bcm.edu/.well-known/openid-configuration}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "Probing: $DISCOVERY_URL" >&2
http_code="$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 15 "$DISCOVERY_URL" 2>/dev/null || echo 000)"

if [ "$http_code" != "200" ]; then
  {
    echo "UNREACHABLE: $DISCOVERY_URL returned HTTP $http_code"
    echo "  -> BCM's OIDC OP is not exposed yet, or not reachable from this host."
    echo "  -> Keep KEYCLOAK_DEFAULT_IDP=bcm + OIDC_IDP_HINT=bcm (SAML fallback)"
    echo "     until this returns 200, then re-run and paste the endpoints below."
  } >&2
  exit 2
fi

python3 - "$tmp" "$DISCOVERY_URL" <<'PY'
import json
import sys

path, url = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception as exc:  # noqa: BLE001 - any parse failure means "not an OIDC OP"
    print(f"NOT-OIDC: {url} did not return a JSON discovery document ({exc})", file=sys.stderr)
    raise SystemExit(2)

required = ["issuer", "authorization_endpoint", "token_endpoint", "jwks_uri"]
missing = [k for k in required if not doc.get(k)]
if missing:
    print(f"INCOMPLETE: discovery doc missing required endpoints: {', '.join(missing)}", file=sys.stderr)
    raise SystemExit(3)

issuer = doc["issuer"]
auth = doc["authorization_endpoint"]
token = doc["token_endpoint"]
userinfo = doc.get("userinfo_endpoint", "")
jwks = doc["jwks_uri"]

claims = doc.get("claims_supported") or []
acr_values = doc.get("acr_values_supported") or []
pkce_methods = doc.get("code_challenge_methods_supported") or []
amr_advertised = "amr" in claims
pkce_s256 = "S256" in pkce_methods

# Human-readable summary -> stderr (so stdout stays a clean, appendable env block).
summary = [
    "OK: BCM OIDC OP is live",
    f"  issuer                 : {issuer}",
    f"  authorization_endpoint : {auth}",
    f"  token_endpoint         : {token}",
    f"  userinfo_endpoint      : {userinfo or '(none advertised)'}",
    f"  jwks_uri               : {jwks}",
    f"  PKCE S256 supported    : {'yes' if pkce_s256 else 'NO — broker forces PKCE; confirm with BCM'}",
    f"  amr in claims_supported: {'yes' if amr_advertised else 'not advertised — verify amr is emitted on a step-up (MFA) login before enabling CHRONICLE_SECURITY_REQUIRE_MFA'}",
]
if acr_values:
    summary.append(f"  acr_values_supported   : {', '.join(acr_values)}")
print("\n".join(summary), file=sys.stderr)

# Paste-ready env block -> stdout.
print("# BCM Shibboleth OIDC OP — discovered endpoints for docker/.env")
print("# After pasting: set KEYCLOAK_DEFAULT_IDP=bcm-oidc and OIDC_IDP_HINT=bcm-oidc.")
print(f"BCM_OIDC_ISSUER={issuer}")
print(f"BCM_OIDC_AUTH_URL={auth}")
print(f"BCM_OIDC_TOKEN_URL={token}")
if userinfo:
    print(f"BCM_OIDC_USERINFO_URL={userinfo}")
print(f"BCM_OIDC_JWKS_URL={jwks}")
print("# BCM_OIDC_CLIENT_ID / BCM_OIDC_CLIENT_SECRET are issued by BCM when you")
print("# register Chronicle's Keycloak as an OIDC relying party. Redirect URI to give BCM:")
print("#   https://chronicle-screentime-app.research.bcm.edu/keycloak/realms/chronicle/broker/bcm-oidc/endpoint")
PY
