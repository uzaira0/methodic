#!/usr/bin/env bash
# Guardrails for infrastructure scripts that used to turn a failure into a success:
# swallowed exit statuses, "best effort" archive flags, weak pass criteria, and host
# ports published on every interface. Each check locks in a fix that an adversarial
# review found; regressions here are silent by construction, which is why they need a test.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FAILURES=0

fail() { printf 'failure-propagation guardrail failed: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf '[ok] %s\n' "$*"; }

require_pattern() { # file regex message
  grep -Eq "$2" "$1" && ok "$3" || fail "$3 ($1)"
}
reject_pattern() { # file regex message
  grep -Eq "$2" "$1" && fail "$3 ($1: $(grep -En "$2" "$1" | head -1))" || ok "$3"
}

# ── k8s TDE init: pg_tde's vault_v2 takes a token FILE PATH, and takes it 4th ─────────
# Passing the token literal 3rd makes pg_tde open the mount path as the token file:
#   ERROR: could not open file "secret" for "vault_token"
# (reproduced against percona/percona-distribution-postgresql:18.6.1-1, pg_tde 2.2).
K8S_TDE="$ROOT_DIR/k8s/base/postgres-init/20-init-db-encryption.sh"
require_pattern "$K8S_TDE" 'vault_token_path' 'k8s TDE init passes a Vault token PATH'
reject_pattern "$K8S_TDE" "PG_TDE_VAULT_TOKEN\}?'?,\s*$" 'k8s TDE init does not pass the raw token as a provider argument'

# Both provider paths must survive the no-principal-key bootstrap state identically.
for tde in "$K8S_TDE" "$ROOT_DIR/docker/init-db-encryption.sh"; do
  count="$(grep -c 'object_not_in_prerequisite_state' "$tde" || true)"
  [[ "$count" -ge 2 ]] \
    && ok "$(basename "$(dirname "$tde")")/$(basename "$tde") guards pg_tde_key_info on both provider paths" \
    || fail "pg_tde_key_info missing the bootstrap guard on one provider path ($tde: $count of 2)"
done

# ── Backups and restore drills must not accept partial results ───────────────────────
K8S_BACKUP="$ROOT_DIR/k8s/backup/local/scripts/backup.sh"
reject_pattern "$K8S_BACKUP" '^[[:space:]]*tar .*ignore-failed-read' 'k8s backup never silently drops unreadable audit logs'
reject_pattern "$K8S_BACKUP" '^[[:space:]]*tar .*warning=no-file-changed' 'k8s backup archives a snapshot, not a changing tree'

DRILL="$ROOT_DIR/docker/restore-drill.sh"
require_pattern "$DRILL" 'pg_restore \\\s*$|--exit-on-error' 'restore drill runs pg_restore --exit-on-error'
reject_pattern "$DRILL" 'pg_restore.*\|\| true' 'restore drill does not discard the pg_restore status'
require_pattern "$DRILL" 'RESTORE_STATUS' 'restore drill checks the pg_restore exit status'
reject_pattern "$DRILL" 'log_warn "Table count mismatch' 'restore drill treats a table-count mismatch as an error'

HETZNER_DRILL="$ROOT_DIR/docker/hetzner/restore-drill.sh"
reject_pattern "$HETZNER_DRILL" 'chronicle-percona:17' 'hetzner restore drill does not default to the retired Percona 17 image'
require_pattern "$HETZNER_DRILL" 'server_version_num' 'hetzner restore drill asserts the server major version'

ROTATE="$ROOT_DIR/scripts/rotate-tde-principal-key.sh"
require_pattern "$ROTATE" 'exit 2' 'TDE rotation reports a distinct partial-failure status'
reject_pattern "$ROTATE" 'run_sql "\$UPSERT_SQL" \\' 'TDE rotation does not reduce a failed tracking upsert to a bare warning'

CHANGELOG="$ROOT_DIR/scripts/changelog-draft.sh"
reject_pattern "$CHANGELOG" 'cliff .*\|\| true' 'changelog draft does not swallow git-cliff failures'

# ── changelog-draft.sh actually exits nonzero on a broken range ──────────────────────
# git-cliff exits 0 on an empty range and 1 on a bad one, so this is a real behavioural
# difference and not just a flag: build a fixture worktree whose recorded public tip does
# not exist and require the draft to abort instead of emitting an incomplete changelog.
if command -v git-cliff >/dev/null 2>&1; then
  fixture="$(mktemp -d)"
  trap 'rm -rf "$fixture"' EXIT
  # A curate worktree git-cliff cannot process (no commits): the draft must abort rather
  # than emit a changelog that silently omits this repository.
  git init -q "$fixture/root"
  status=0
  CHRONICLE_PUBLISH_WORK="$fixture" "$CHANGELOG" 0.0.0 >/dev/null 2>&1 || status=$?
  [[ "$status" -ne 0 ]] \
    && ok "changelog-draft.sh exits $status when git-cliff cannot process a worktree" \
    || fail "changelog-draft.sh exited 0 despite a git-cliff failure; the draft would be incomplete"
else
  ok "git-cliff not installed — skipping the changelog behavioural check"
fi

# ── Published host ports must be loopback-bound ──────────────────────────────────────
for spec in \
  "docker/docker-compose.dev.yml|40320" \
  "docker/docker-compose.temporal.yml|7233"; do
  f="${spec%%|*}"; port="${spec#*|}"
  BAD="$(grep -En "^[[:space:]]*-[[:space:]]*\"${port}:" "$ROOT_DIR/$f" || true)"
  [[ -z "$BAD" ]] \
    && ok "$f publishes $port on 127.0.0.1 only" \
    || fail "$f publishes $port on every interface: $BAD"
  require_pattern "$ROOT_DIR/$f" "127\.0\.0\.1:${port}:" "$f binds $port to loopback"
done

# ── Makefile perf targets must name Compose SERVICES, not container names ────────────
# `chronicle-postgres` is the container_name; the service key is `postgres`, so the old
# target died with "no such service: chronicle-postgres".
if command -v docker >/dev/null 2>&1 && \
   SERVICES="$(cd "$ROOT_DIR/docker" && docker compose -f docker-compose.traefik.yml config --services 2>/dev/null)"; then
  for svc in $(grep -oE 'docker compose .* up -d [a-z0-9 -]+' "$ROOT_DIR/Makefile" | sed 's/.* up -d //'); do
    grep -qx "$svc" <<<"$SERVICES" \
      && ok "Makefile perf-up service '$svc' exists in docker-compose.traefik.yml" \
      || fail "Makefile names '$svc', which is not a Compose service (container names are not services)"
  done
else
  ok "docker compose unavailable — skipping the Makefile service-name check"
fi

echo
if [[ "$FAILURES" -gt 0 ]]; then
  printf 'failure-propagation guardrails: %d failure(s)\n' "$FAILURES" >&2
  exit 1
fi
printf 'failure-propagation guardrails: all checks passed\n'
