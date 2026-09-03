#!/bin/sh
# Makes the local-https mode's certificate authority reachable by a human with a phone.
#
# In that mode Caddy signs the server certificate with a CA it generated itself, so every
# device rejects the server until that CA is installed on it. The CA is already downloadable
# at http://$DOMAIN/local-ca.crt (see the :80 block in Caddyfile.split.local); this only
# solves the last step, which is getting that URL into a phone without typing an IP address
# into a mobile browser.
#
# Runs once, after web is healthy, and only in overlays/mode-local-https.yml.
set -eu

CA_SRC=/data/caddy/pki/authorities/local/root.crt
CA_OUT=/out/local-ca.crt
if [ "${LOCAL_HTTP_PORT:-80}" = 80 ]; then
  URL="http://${DOMAIN}/local-ca.crt"
else
  URL="http://${DOMAIN}:${LOCAL_HTTP_PORT}/local-ca.crt"
fi

# Caddy provisions the CA lazily, on the first certificate it issues. The healthcheck web
# waits for proves the listener answers, which is after that -- but the file is written by a
# background job, so allow a few seconds rather than racing it.
i=0
while [ ! -s "$CA_SRC" ] && [ "$i" -lt 30 ]; do
  i=$((i + 1))
  sleep 1
done

if [ ! -s "$CA_SRC" ]; then
  echo "FATAL: Caddy has not created a local CA at ${CA_SRC}." >&2
  echo "       Is DOMAIN=${DOMAIN} an address this machine actually has? Caddy cannot" >&2
  echo "       issue a certificate for a name that resolves nowhere." >&2
  exit 1
fi

# A copy beside the compose file, for the researcher's own laptop and for any device that
# is easier to load a file onto than to point at a URL.
cp "$CA_SRC" "$CA_OUT"
chmod 644 "$CA_OUT"

echo
echo "======================================================================"
echo " Install this stack's certificate authority on each test phone"
echo "======================================================================"
echo
echo "  1. Put the phone on the SAME wifi as this machine."
echo "  2. Scan the QR code below, or open:  ${URL}"
echo "  3. Android: Settings -> Security -> Encryption & credentials ->"
echo "             Install a certificate -> CA certificate."
echo "     iOS:     the profile downloads, then Settings -> General ->"
echo "             VPN & Device Management -> install it, THEN"
echo "             Settings -> General -> About -> Certificate Trust"
echo "             Settings -> turn it on. iOS needs both steps."
echo
qrencode -t ANSIUTF8 -m 2 "$URL" || echo "  (could not render the QR code — use the URL above)"
echo
echo "  A copy is also in the configured state directory at tls/local-ca.crt."
echo
echo "  ANDROID APP NOTE: a user-installed CA is trusted by browsers but NOT by apps,"
echo "  unless the app opts in. The Chronicle 'open' build must ship a"
echo "  network-security-config that trusts user CAs, or enrollment fails with a TLS"
echo "  error while the same URL loads fine in Chrome on the same phone."
echo
echo "  This CA is for YOUR OWN test devices. Do not ask participants to install it —"
echo "  for a real study use a certificate their phones already trust"
echo "  (overlays/mode-behind-proxy-internal.yml or overlays/mode-own-tls-internal.yml)."
echo "======================================================================"
echo
