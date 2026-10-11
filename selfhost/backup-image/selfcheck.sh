#!/usr/bin/env bash
set -Eeuo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
backups_dir="${BACKUPS_DIR:-${BACKUP_DIR:-/backups}}"
umask 077
exec 9>"${backups_dir}/.selfcheck.lock"
flock -n 9 || { echo 'Restore self-check FAIL: self-check already running' >&2; exit 1; }
exec python3 "${script_dir}/selfcheck.py" "$@"
