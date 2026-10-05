#!/usr/bin/env bash
# cert-init.sh against a scratch ./tls: atomic internal-pair generation, rejection of unusable
# existing pairs, and operator-owned files that a plain cp can renew.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
command -v openssl >/dev/null || { echo "FAIL: missing tool: openssl" >&2; exit 1; }
RUN_PARENT="${ROOT_DIR}/build/operator-test-runs/selfhost-cert-init"
mkdir -p "$RUN_PARENT"
RUN_DIR=$(mktemp -d "${RUN_PARENT}/run.XXXXXX")
trap 'rm -rf -- "$RUN_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The container runs as root; here chown only records what cert-init asked for.
mkdir -p "$RUN_DIR/bin"
cat >"$RUN_DIR/bin/chown" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CERT_INIT_CHOWN_LOG"
EOF
chmod +x "$RUN_DIR/bin/chown"
export CERT_INIT_CHOWN_LOG="$RUN_DIR/chown.log"
TLS="$RUN_DIR/tls"

cert_init() { # <TLS_MODE>
  env PATH="$RUN_DIR/bin:$PATH" TLS_DIR="$TLS" TLS_MODE="$1" DASHBOARD_EXPOSURE=internal \
    bash "$ROOT_DIR/selfhost/cert-init.sh" >"$RUN_DIR/output" 2>&1
}
pair_matches() { # <cert> <key>
  [[ "$(openssl x509 -in "$1" -noout -pubkey)" == "$(openssl pkey -in "$2" -pubout)" ]]
}
mode() { stat -c '%a' "$1"; }

# Fresh generation publishes a matching pair, leaves no temporaries, and keeps the files
# owned by the owner of ./tls, group 0, key 0640.
mkdir "$TLS"
cert_init behind-proxy || { cat "$RUN_DIR/output" >&2; fail 'fresh generation failed'; }
pair_matches "$TLS/internal-cert.pem" "$TLS/internal-key.pem" || fail 'generated pair does not match'
[[ -z "$(find "$TLS" -name '.internal-*')" ]] || fail 'generation left temporary files'
[[ "$(mode "$TLS/internal-key.pem")" == 640 && "$(mode "$TLS/internal-cert.pem")" == 644 ]] \
  || fail 'unexpected generated modes'
grep -Eq "^$(id -u):0 $TLS/\.?internal-key" "$CERT_INIT_CHOWN_LOG" \
  || fail 'key was not left owned by the ./tls owner in group 0'
echo 'PASS: fresh internal pair generated atomically, operator-owned, group-readable by Caddy'

# A nonempty but truncated certificate (an interrupted older write) is not accepted.
good_key=$(<"$TLS/internal-key.pem")
head -c 200 "$TLS/internal-cert.pem" >"$TLS/internal-cert.trunc" && mv "$TLS/internal-cert.trunc" "$TLS/internal-cert.pem"
chmod 0644 "$TLS/internal-key.pem"   # as a careless copy leaves it
cert_init behind-proxy || { cat "$RUN_DIR/output" >&2; fail 'truncated certificate was not regenerated'; }
pair_matches "$TLS/internal-cert.pem" "$TLS/internal-key.pem" || fail 'regenerated pair does not match'
[[ -s "$TLS/internal-cert.pem.invalid" && -s "$TLS/internal-key.pem.invalid" ]] || fail 'invalid pair not kept aside'
[[ "$(<"$TLS/internal-key.pem")" != "$good_key" ]] || fail 'stale key reused with a new certificate'
[[ "$(mode "$TLS/internal-key.pem.invalid")" == 600 ]] || fail 'key moved aside is readable by others'
echo 'PASS: truncated existing certificate is moved aside and regenerated'

# Regression V-25: the generated pair is replaced in its last 30 days; an operator's own
# certificate near expiry is kept and only warned about.
rm -f "$TLS"/internal-*
openssl req -x509 -newkey rsa:2048 -nodes -days 5 -subj /CN=chronicle-dashboard \
  -keyout "$TLS/internal-key.pem" -out "$TLS/internal-cert.pem" >/dev/null 2>&1
expiring_cert=$(<"$TLS/internal-cert.pem")
cert_init behind-proxy || { cat "$RUN_DIR/output" >&2; fail 'expiring generated certificate was not renewed'; }
[[ "$(<"$TLS/internal-cert.pem.expired")" == "$expiring_cert" ]] || fail 'expiring pair not kept aside'
openssl x509 -checkend $((30 * 86400)) -noout -in "$TLS/internal-cert.pem" >/dev/null ||
  fail 'renewed certificate still expires within 30 days'
pair_matches "$TLS/internal-cert.pem" "$TLS/internal-key.pem" || fail 'renewed pair does not match'
openssl req -x509 -newkey rsa:2048 -nodes -days 5 -subj /CN=dashboard.example.org \
  -keyout "$TLS/internal-key.pem" -out "$TLS/internal-cert.pem" >/dev/null 2>&1
operator_cert=$(<"$TLS/internal-cert.pem")
cert_init behind-proxy || { cat "$RUN_DIR/output" >&2; fail 'expiring operator certificate refused'; }
[[ "$(<"$TLS/internal-cert.pem")" == "$operator_cert" ]] || fail 'operator certificate was replaced'
grep -Fq 'expires within 30 days; replace' "$RUN_DIR/output" || fail 'no expiry warning for operator certificate'
echo 'PASS: expiring generated pair renewed; operator certificate kept with a warning'

# A failed generation publishes nothing at the final names.
rm -f "$TLS"/internal-*
cat >"$RUN_DIR/bin/openssl" <<'EOF'
#!/usr/bin/env bash
# Write a partial key, then die as on a full disk.
for ((i = 1; i <= $#; i++)); do [[ "${!i}" == -keyout ]] && { j=$((i + 1)); printf 'partial' >"${!j}"; }; done
exit 1
EOF
chmod +x "$RUN_DIR/bin/openssl"
! cert_init behind-proxy || fail 'failed generation reported success'
rm "$RUN_DIR/bin/openssl"
[[ ! -e "$TLS/internal-key.pem" && ! -e "$TLS/internal-cert.pem" ]] || fail 'failed generation left final files'
[[ -z "$(find "$TLS" -name '.internal-*')" ]] || fail 'failed generation left temporary files'
echo 'PASS: interrupted generation leaves nothing that a later start would accept'

# Own TLS: a mismatched operator pair is refused, never silently accepted.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=a -keyout "$TLS/key.pem" -out "$TLS/cert.pem" >/dev/null 2>&1
openssl genpkey -algorithm RSA -out "$TLS/other-key.pem" >/dev/null 2>&1
cp "$TLS/key.pem" "$RUN_DIR/own-key.pem"
cp "$TLS/other-key.pem" "$TLS/key.pem"
chmod 0644 "$TLS/key.pem"
! cert_init own-tls || fail 'mismatched own-tls pair accepted'
[[ "$(mode "$TLS/key.pem")" == 600 ]] || fail 'rejected own-tls key left readable by others'
grep -Fq 'not a matching certificate' "$RUN_DIR/output" || fail 'missing own-tls mismatch diagnostic'
cp "$RUN_DIR/own-key.pem" "$TLS/key.pem"   # renewal with a plain cp
cert_init own-tls || { cat "$RUN_DIR/output" >&2; fail 'matching own-tls pair refused'; }
grep -Fqx "$(id -u):0 $TLS/key.pem" "$CERT_INIT_CHOWN_LOG" || fail 'own key not left with the ./tls owner'
[[ "$(mode "$TLS/key.pem")" == 640 ]] || fail 'own key mode is not 0640'
echo 'PASS: own-tls pair validated and left operator-owned'
echo 'PASS: selfhost-cert-init'
