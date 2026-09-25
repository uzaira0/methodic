#!/usr/bin/env bash
# postgres-backup-local hook, mounted as /hooks/50-prune-pre-operation-dumps and run by
# run-parts with the phase as $1 (pre-backup, post-backup or error).
#
# upgrade.sh and restore.sh write full-database safety dumps (pre-upgrade-*.sql.gz,
# pre-restore-*.sql.gz and their .continuity.sql.gz companions) into the backups root. The
# image's rotation only prunes last/daily/weekly/monthly, so without this those copies, and
# every row deleted since they were taken, would stay on disk forever. Restore and upgrade
# stop this sidecar while they run, so a dump in active use is never pruned here.
set -euo pipefail

[[ "${1:-}" == post-backup ]] || exit 0

keep_days="${PRE_OP_BACKUP_KEEP_DAYS:-30}"
[[ "$keep_days" =~ ^[1-9][0-9]{0,3}$ ]] || {
  echo "ERROR: PRE_OP_BACKUP_KEEP_DAYS must be a whole number of days from 1 to 9999" >&2
  exit 1
}

find "${BACKUP_DIR:-/backups}" -maxdepth 1 -type f \
  \( -name 'pre-upgrade-*.sql.gz' -o -name 'pre-restore-*.sql.gz' \) \
  -mtime "+${keep_days}" -print -delete |
  sed 's/^/Pruned pre-operation safety dump older than '"${keep_days}"' days: /'
