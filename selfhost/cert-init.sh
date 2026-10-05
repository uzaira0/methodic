#!/usr/bin/env bash
# Prepares ./tls so Caddy can actually read what it is asked to serve, as a one-shot compose
# service so `docker compose up -d` produces a working stack with no prior step. It has two
# jobs, and which ones apply is decided by the mode overlay that set TLS_MODE and
# DASHBOARD_EXPOSURE on this service.
#
# Both jobs exist because of the same constraint: Caddy runs as uid 10001, gid 0, with
# cap_drop: ALL. It can read a key only through the group-read bit, so a private key at 0600
# owned by anyone else is unreadable and the listener fails to start.
set -euo pipefail

: "${TLS_MODE:=behind-proxy}"
: "${DASHBOARD_EXPOSURE:=public}"
: "${DOMAIN:=localhost}"
: "${INTERNAL_BIND:=127.0.0.1}"
: "${INTERNAL_CERT_SANS:=}"
: "${TLS_DIR:=/tls}"

# Docker creates a missing bind-mount source as 0755 root, which is already traversable.
# Set it anyway so a directory the operator created as 0700 does not silently deny Caddy.
chmod 755 "$TLS_DIR"

# Caddy runs as uid 10001, gid 0 with no capabilities: it reads a file through the owner bits
# only if it owns it, otherwise through the group bits for gid 0. So each file stays owned by
# whoever owns ./tls (the operator, who can then renew it with a plain cp), in group 0, and
# the key is 0640: readable by Caddy, never world-readable on the host. A root-owned ./tls,
# or an owner this container cannot map, falls back to root ownership.
TLS_OWNER="$(stat -c %u "$TLS_DIR")"
protect() { # <path> <mode>
  chown "${TLS_OWNER}:0" "$1" 2>/dev/null || chown 0:0 "$1"
  chmod "$2" "$1"
}

# A nonempty file is not necessarily usable: accept only a certificate and private key that
# parse and belong together. -passin keeps an encrypted key from waiting for a passphrase.
valid_pair() { # <cert> <key>
  local cert_public key_public
  cert_public="$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null)" &&
    key_public="$(openssl pkey -passin pass: -in "$2" -pubout 2>/dev/null)" &&
    [[ -n "$cert_public" && "$cert_public" == "$key_public" ]]
}

# ------------------------------------------------------------- the operator's certificate
if [[ "$TLS_MODE" == own-tls ]]; then
  if [[ -s "$TLS_DIR/cert.pem" && -s "$TLS_DIR/key.pem" ]]; then
    # Close a copied key to others first, so a key this check rejects is not left readable.
    chmod go-rwx "$TLS_DIR/key.pem"
    valid_pair "$TLS_DIR/cert.pem" "$TLS_DIR/key.pem" || {
      echo "FATAL: ./tls/cert.pem and ./tls/key.pem are not a matching certificate and unencrypted private key" >&2
      exit 1
    }
    protect "$TLS_DIR/cert.pem" 644
    protect "$TLS_DIR/key.pem" 640
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

CRT="$TLS_DIR/internal-cert.pem"
KEY="$TLS_DIR/internal-key.pem"

# Idempotent, so replacing these two files with a real certificate survives every `up`.
if [[ -s "$CRT" && -s "$KEY" ]]; then
  # Close a copied key to others first, so a key moved aside below is not left readable.
  chmod go-rwx "$KEY"
  if valid_pair "$CRT" "$KEY"; then
    # The generated pair lasts 825 days and nothing else renews it: replace it in its last 30
    # days. An operator's own certificate (any other subject) is theirs to renew; only warn.
    if openssl x509 -checkend $((30 * 86400)) -noout -in "$CRT" >/dev/null 2>&1; then
      expiring=false
    else
      expiring=true
    fi
    if [[ "$expiring" == false ||
      "$(openssl x509 -noout -subject -nameopt RFC2253 -in "$CRT" 2>/dev/null)" != 'subject=CN=chronicle-dashboard' ]]; then
      [[ "$expiring" == false ]] ||
        echo "  warn ./tls/internal-cert.pem expires within 30 days; replace both internal-*.pem files" >&2
      protect "$CRT" 644
      protect "$KEY" 640
      echo "  ok   internal dashboard certificate already present (./tls/internal-cert.pem)"
      exit 0
    fi
    mv -f "$CRT" "$CRT.expired"
    mv -f "$KEY" "$KEY.expired"
    echo "  warn generated internal certificate expires within 30 days; moved aside as *.expired"
  else
    # Otherwise Caddy could never start. Keep the unusable pair for inspection and regenerate.
    mv -f "$CRT" "$CRT.invalid"
    mv -f "$KEY" "$KEY.invalid"
    echo "  warn internal certificate and key were not a matching pair; moved aside as *.invalid"
  fi
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

# Generate beside the final names and rename only a complete, matching pair, so an
# interruption or a full disk never leaves files that the check above would have to reject.
TMP_KEY="$(mktemp "$TLS_DIR/.internal-key.XXXXXX")"
TMP_CRT="$(mktemp "$TLS_DIR/.internal-cert.XXXXXX")"
trap 'rm -f "$TMP_KEY" "$TMP_CRT"' EXIT
{ openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
    -keyout "$TMP_KEY" -out "$TMP_CRT" -subj "/CN=chronicle-dashboard" \
    -addext "subjectAltName=${SAN}" >/dev/null 2>&1 && valid_pair "$TMP_CRT" "$TMP_KEY"; } \
  || { echo "FATAL: could not generate the internal dashboard certificate" >&2; exit 1; }

protect "$TMP_CRT" 644
protect "$TMP_KEY" 640
mv -f "$TMP_KEY" "$KEY"
mv -f "$TMP_CRT" "$CRT"

echo "  ok   generated a self-signed certificate for the dashboard (./tls/internal-cert.pem)"
echo "       SANs: ${SAN}"
echo "       Browsers will warn until you trust it; replace both files to use a real cert."
