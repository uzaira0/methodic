#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CLI="${ROOT_DIR}/selfhost/chronicle"
README="${ROOT_DIR}/selfhost/README.md"
WORK_DIR=/home/opt/chronicle_work/launch-audit-1003/sol/webselfhost-logs
RUN_DIR="$(mktemp -d "${WORK_DIR}/W81.XXXXXX")"
trap 'rm -rf -- "$RUN_DIR"' EXIT
BIN_DIR="${RUN_DIR}/bin"
mkdir -p "$BIN_DIR"

fail() { echo "FAIL W81: $*" >&2; exit 1; }

grep -Fq 'must also redirect requests arriving over external HTTP to the canonical HTTPS origin' "$README" ||
  fail 'behind-proxy instructions omit the owner-managed HTTP-to-HTTPS redirect prerequisite'
grep -Fq 'Location: https://chronicle.your-university.edu/health' "$README" ||
  fail 'behind-proxy instructions omit the exact HTTPS health redirect target'
grep -Fq 'check_proxy_http_redirect() {' "$CLI" ||
  fail 'verify has no bounded canonical HTTP redirect check'

sed -n '/^check_proxy_http_redirect() {/,/^}/p' "$CLI" >"${RUN_DIR}/redirect-check.sh"
grep -q '^check_proxy_http_redirect() {' "${RUN_DIR}/redirect-check.sh" ||
  fail 'could not isolate the redirect check for the controlled edge fixture'

cat >"${BIN_DIR}/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
[[ "$args" == *' --connect-timeout 5 '* && "$args" == *' --max-time 10 '* ]] || {
  echo 'redirect probe omitted its connection or transfer deadline' >&2
  exit 90
}
[[ "$args" != *' --location '* && "$args" != *' -L '* ]] || {
  echo 'redirect probe followed the response instead of checking Location' >&2
  exit 91
}
[[ "${!#}" == "$W81_HTTP_URL" ]] || exit 92
case "$W81_MODE" in
  redirect)
    printf 'HTTP/1.1 308 Permanent Redirect\r\nLocation: %s\r\n\r\n\n308' "$W81_LOCATION"
    ;;
  wrong-location)
    printf 'HTTP/1.1 301 Moved Permanently\r\nLocation: https://other.example/health\r\n\r\n\n301'
    ;;
  nonredirect)
    printf 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n\n200'
    ;;
  *) exit 93 ;;
esac
SH
chmod 0755 "${BIN_DIR}/curl"

export PATH="${BIN_DIR}:${PATH}"
export W81_HTTP_URL='http://chronicle.example.edu/health'
export W81_LOCATION='https://chronicle.example.edu/health'
# This function is exercised only against the local curl stub; the regression performs no
# HTTP request to a real hostname or loopback listener.
source "${RUN_DIR}/redirect-check.sh"
status="$(W81_MODE=redirect check_proxy_http_redirect "$W81_HTTP_URL" "$W81_LOCATION")" ||
  fail 'accepted canonical redirect fixture did not return its status'
[[ "$status" == 308 ]] || fail "accepted redirect returned unexpected status $status"
if W81_MODE=nonredirect check_proxy_http_redirect "$W81_HTTP_URL" "$W81_LOCATION" >/dev/null; then
  fail 'nonredirecting edge fixture was accepted'
fi
if W81_MODE=wrong-location check_proxy_http_redirect "$W81_HTTP_URL" "$W81_LOCATION" >/dev/null; then
  fail 'redirect to a different HTTPS authority was accepted'
fi
echo 'PASS W81: docs require owner proxy redirect; bounded verify accepts exact HTTPS Location and rejects controlled failures'
