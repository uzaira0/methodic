#!/usr/bin/env bash
set -euo pipefail

printf 'invoked\n' > "${LEGACY_RESTORE_TEST_MIGRATE_MARKER:?}"
exit "${LEGACY_RESTORE_TEST_MIGRATE_TDE_EXIT:-0}"
