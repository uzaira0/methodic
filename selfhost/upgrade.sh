#!/usr/bin/env bash
# Compatibility entry point; the operator CLI owns upgrade orchestration.
set -Eeuo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec "$script_dir/chronicle" upgrade "$@"
