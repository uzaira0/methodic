#!/usr/bin/env bash
# Prepares ./tls so Caddy can actually read what it is asked to serve, as a one-shot compose
# service so `docker compose up -d` produces a working stack with no prior step. It has two
# jobs, and which ones apply is decided by the mode overlay that set TLS_MODE and
# DASHBOARD_EXPOSURE on this service.
#
# Both jobs exist because of the same constraint: Caddy runs as root inside its container but
# with cap_drop: ALL, so it has neither DAC_OVERRIDE nor DAC_READ_SEARCH and CANNOT read a
# key file the way root normally would. A private key at 0600 owned by anyone else is simply
# unreadable, and the listener fails to start.
set -euo pipefail

: "${TLS_MODE:=behind-proxy}"
: "${DASHBOARD_EXPOSURE:=public}"
: "${DOMAIN:=localhost}"
: "${INTERNAL_BIND:=127.0.0.1}"
: "${INTERNAL_CERT_SANS:=}"

# Docker creates a missing bind-mount source as 0755 root, which is already traversable.
# Set it anyway so a directory the operator created as 0700 does not silently deny Caddy.
chmod 755 /tls

# Owned by root at 0600: the Caddy container's root user reads it as the owner, needing no
# capability, and no other account on the host can read it. This is why the key is chowned
# rather than made 0644 -- a world-readable private key on the host would be the cost of
# making it readable inside the container, and it is not necessary.
protect_key() {
  chown 0:0 "$1"
  chmod 600 "$1"
}

# ------------------------------------------------------------- the operator's certificate
if [[ "$TLS_MODE" == own-tls ]]; then
  if [[ -s /tls/cert.pem && -s /tls/key.pem ]]; then
    chmod 644 /tls/cert.pem
    protect_key /tls/key.pem
    echo "  ok   ./tls/cert.pem and ./tls/key.pem prepared for Caddy"
  else
    echo "FATAL: TLS_MODE=own-tls but ./tls/cert.pem or ./tls/key.pem is missing or empty" >&2
    exit 1
  fi
fi

# ------------------------------------------------------- the internal dashboard listener
# The internal listener runs TLS so the dashboard password never crosses the wire in clear.
# Caddy's own `tls internal` cannot serve it: the site block is a bare :PORT reached by IP,
# so the local CA has no name to issue for and the handshake fails outright. A self-signed
# certificate with explicit IP SANs does work.
[[ "$DASHBOARD_EXPOSURE" == internal ]] || exit 0

CRT=/tls/internal-cert.pem
KEY=/tls/internal-key.pem

# Idempotent, so replacing these two files with a real certificate survives every `up`.
if [[ -s "$CRT" && -s "$KEY" ]]; then
  chmod 644 "$CRT"
  protect_key "$KEY"
  echo "  ok   internal dashboard certificate already present (./tls/internal-cert.pem)"
  exit 0
fi

# The participant-facing DOMAIN is deliberately NOT in this certificate. The public listener
# owns that name through either Caddy's local CA or the operator's real certificate. Loading a
# second self-signed certificate for the same name lets Caddy select the dashboard certificate
# on the public listener and breaks the documented CA trust path for Android. The private
# dashboard defaults to localhost/INTERNAL_BIND; an operator who needs another management-only
# name can add it explicitly through INTERNAL_CERT_SANS.
SAN="DNS:localhost,IP:127.0.0.1"
[[ "$INTERNAL_BIND" != 127.0.0.1 && "$INTERNAL_BIND" != 0.0.0.0 ]] && SAN="${SAN},IP:${INTERNAL_BIND}"
[[ -n "$INTERNAL_CERT_SANS" ]] && SAN="${SAN},${INTERNAL_CERT_SANS}"

openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
  -keyout "$KEY" -out "$CRT" -subj "/CN=chronicle-dashboard" \
  -addext "subjectAltName=${SAN}" >/dev/null 2>&1 \
  || { echo "FATAL: could not generate the internal dashboard certificate" >&2; exit 1; }

chmod 644 "$CRT"
protect_key "$KEY"

echo "  ok   generated a self-signed certificate for the dashboard (./tls/internal-cert.pem)"
echo "       SANs: ${SAN}"
echo "       Browsers will warn until you trust it; replace both files to use a real cert."
