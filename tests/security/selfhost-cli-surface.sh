#!/usr/bin/env bash
# Operator CLI contract: help lists every dispatched command, argument-free commands refuse
# arguments instead of acting, diagnostics are time-bounded, setup never hands out a taken
# Grafana port, and the internal-listener guard meters password guessing.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
CLI="$ROOT_DIR/selfhost/chronicle"
SNIPPETS="$ROOT_DIR/selfhost/caddy/snippets.caddy"
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$HOME/tmp"
RUN_DIR=$(mktemp -d -p "$HOME/tmp" selfhost-cli-surface.XXXXXX)
trap 'rm -rf -- "$RUN_DIR"' EXIT

# 1. Help covers every dispatched command (X1, C4-3).
help_output=$(bash "$CLI" help)
dispatched=$(awk '/^case "\$\{1:-help\}" in/ {on=1; next} on && /^esac/ {exit}
  on && /^  [a-z-]+\)/ {sub(/^  /, ""); sub(/\).*/, ""); print}' "$CLI")
[[ -n "$dispatched" ]] || fail 'could not read the command dispatcher'
while read -r command; do
  grep -Eq "\./chronicle ${command}( |$)" <<<"$help_output" || fail "help omits dispatched command: $command"
done <<<"$dispatched"
grep -Fq './chronicle upgrade --from DIR' <<<"$help_output" || fail 'help omits upgrade --from DIR'
echo 'PASS: help lists every dispatched command'

# 2. `down --help` must not run `docker compose down` (C4-3).
mkdir -p "$RUN_DIR/bin" "$RUN_DIR/selfhost"
cp "$CLI" "$RUN_DIR/selfhost/chronicle"
printf 'COMPOSE_PROJECT_NAME=cli-surface\n' >"$RUN_DIR/selfhost/.env"
printf '#!/bin/sh\necho "$@" >> "%s/docker-calls"\n' "$RUN_DIR" >"$RUN_DIR/bin/docker"
chmod +x "$RUN_DIR/bin/docker"
status=0
PATH="$RUN_DIR/bin:$PATH" bash "$RUN_DIR/selfhost/chronicle" down --help >"$RUN_DIR/out" 2>&1 || status=$?
[[ $status -ne 0 ]] || fail 'down --help exited 0'
grep -Fq 'usage: ./chronicle down' "$RUN_DIR/out" || fail 'down --help printed no usage'
! grep -q 'down' "$RUN_DIR/docker-calls" 2>/dev/null || fail 'down --help ran docker compose down'
echo 'PASS: down refuses arguments before touching Compose'

# 3. Doctor's in-container probes are time-bounded (B6).
while read -r line; do
  grep -Eq 'wget .*-T [0-9]+' <<<"$line" || fail "unbounded wget in doctor: $line"
done < <(grep -E 'dc exec -T grafana wget' "$CLI")
echo 'PASS: doctor wget probes carry -T'

# 4. Setup picks a free Grafana port like the other listeners (C4-1).
grep -Eq 'grafana_port=\$\(free_port "\$\{GRAFANA_PORT:-3000\}"' "$CLI" \
  || fail 'setup does not choose a free GRAFANA_PORT'
grep -Fq "('GRAFANA_PORT', grafana_port)" "$CLI" || fail 'setup does not write GRAFANA_PORT to .env'
echo 'PASS: setup selects and writes a free Grafana port'

# 5. The internal-listener guard meters every request per TCP peer before basic_auth (B3, S2).
guard=$(awk '/^\(chronicle_dashboard_guard\) \{/ {on=1} on {print} on && /^\}/ {exit}' "$SNIPPETS")
rl_line=$(grep -n 'rate_limit' <<<"$guard" | head -1 | cut -d: -f1 || true)
ba_line=$(grep -n 'basic_auth' <<<"$guard" | head -1 | cut -d: -f1 || true)
[[ -n "$rl_line" && -n "$ba_line" && "$rl_line" -lt "$ba_line" ]] \
  || fail 'chronicle_dashboard_guard has no rate_limit ahead of basic_auth'
grep -Fq 'key {remote_ip}' <<<"$guard" || fail 'guard rate limit is not keyed on the TCP peer'
echo 'PASS: internal guard rate-limits before basic_auth'

# 6. SPA headers: CSP, immutable hashed assets, uncached shell (CH21, C3).
grep -Fq "Content-Security-Policy \"default-src 'self'" "$SNIPPETS" || fail 'no Content-Security-Policy'
grep -Fq "frame-ancestors 'none'" "$SNIPPETS" || fail 'CSP lacks frame-ancestors'
grep -Fq 'Cache-Control "public, max-age=31536000, immutable"' "$SNIPPETS" || fail 'hashed assets not immutable'
grep -Fq 'Cache-Control "no-cache"' "$SNIPPETS" || fail 'SPA shell may be heuristically cached'
echo 'PASS: SPA security and cache headers present'

# 7. Time sync and free-space floor are checked by the CLI (R6, R7).
grep -Fq 'NTPSynchronized' "$CLI" || fail 'no time-sync check'
grep -Fq 'MIN_FREE_DISK_GIB' "$CLI" || fail 'no free-space floor before up'
echo 'PASS: time sync and free-space floor checks present'

# 8. Restore receipts record a duration (L5).
grep -Fq 'durationSeconds' "$CLI" || fail 'operation receipts carry no duration'
echo 'PASS: operation receipts record duration'
# 9. A mistyped command fails loudly; asking for help succeeds (I9).
for help_arg in help --help -h; do
  bash "$CLI" "$help_arg" >"$RUN_DIR/help.out" 2>&1 || fail "./chronicle $help_arg exited non-zero"
  grep -Fq './chronicle down' "$RUN_DIR/help.out" || fail "./chronicle $help_arg printed no command list"
done
status=0
bash "$CLI" stauts >"$RUN_DIR/typo.out" 2>"$RUN_DIR/typo.err" || status=$?
[[ $status -eq 2 ]] || fail "unknown command exited ${status}, want 2"
[[ ! -s "$RUN_DIR/typo.out" ]] || fail 'unknown command wrote help to stdout'
grep -Fq "unknown command 'stauts'" "$RUN_DIR/typo.err" || fail 'unknown command was not named on stderr'
echo 'PASS: unknown commands exit 2; help exits 0'

# 10. The trial wizard refuses a public address, the same rule config-guard enforces (S8), and
#     the production prompt does not suggest a reserved documentation name (C3).
trial=$(awk '/if \[\[ "\$tls_mode" == local-https \]\]; then/ {on=1} on {print} on && /^  else$/ {exit}' "$CLI")
grep -Fq 'guard-config.sh --validate-public-host "$domain"' <<<"$trial" \
  || fail 'setup trial branch does not refuse a public address'
! grep -Fq 'e.g. study.example.org' "$CLI" || fail 'setup suggests a hostname its own guard rejects'
echo 'PASS: setup trial branch refuses public addresses'
# 11. Operator docs cover what the launch audit found missing (I7, I8, I9, S5, S6, K1, K3, D4, D5, D6, R4).
DOCS="$ROOT_DIR/selfhost"
doc_has() { grep -Fq -- "$2" "$DOCS/$1" || fail "$1 does not document: $2"; }
doc_has README.md '| Host | Tested |'
doc_has README.md 'selinux-enabled'
doc_has README.md 'docker` group'
doc_has README.md 'root-equivalent'
doc_has README.md 'sha256sum -c chronicle-selfhost-'
doc_has README.md '## Security updates'
doc_has README.md './chronicle update --check'
doc_has README.md 'docs/INCIDENT-RESPONSE.md'
doc_has docs/INCIDENT-RESPONSE.md '## 1. Collect'
doc_has docs/INCIDENT-RESPONSE.md '## 2. Isolate'
doc_has docs/INCIDENT-RESPONSE.md '## 3. Rotate'
doc_has docs/INCIDENT-RESPONSE.md '## 4. Notify'
doc_has docs/BACKUP-RESTORE.md '## Verify off-host copies'
doc_has docs/BACKUP-RESTORE.md 'rclone check'
doc_has docs/BACKUP-RESTORE.md 'PRE_OP_BACKUP_KEEP_DAYS'
doc_has docs/BACKUP-RESTORE.md 'accepted residual risk'
doc_has docs/UNINSTALL-DATA-DELETION.md 'pre-restore-*.sql.gz'
doc_has docs/UNINSTALL-DATA-DELETION.md 'pre-upgrade-*.sql.gz'
doc_has docs/UNINSTALL-DATA-DELETION.md 'PRE_OP_BACKUP_KEEP_DAYS'
doc_has README.md 'shasum -a 256 -c chronicle-selfhost-'
# legal P2: operators must be told what the platform records whatever modules they pick.
doc_has docs/CHILE-LEY-21719.md '## Data the platform records regardless of modules'
doc_has docs/CHILE-LEY-21719.md 'audit_logs.ip_address'
doc_has docs/CHILE-LEY-21719.md 'no purge job'
doc_has docs/CHILE-LEY-21719.md 'device model, brand'
doc_has README.md 'CHILE-LEY-21719.md#data-the-platform-records-regardless-of-modules'
! grep -Fq 'git clone' <(awk '/^## Quick start/ {on=1; next} on && /^## / {exit} on' "$DOCS/README.md" | head -12) \
  || fail 'README Quick start still opens with a source clone instead of the release bundle'
echo 'PASS: operator docs cover OS matrix, rights, security updates, incidents, and backup retention'
echo 'PASS: selfhost-cli-surface'
