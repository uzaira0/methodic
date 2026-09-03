#!/usr/bin/env bash
# Hardcoded-English guard across the monorepo. Exits non-zero on the first surface with findings.
#   make i18n-lint            everything
#   scripts/i18n-lint.sh web|android|server|ios   one surface
# Needs: ast-grep (cargo install ast-grep), semgrep (pip install semgrep), jq, bun (web only).
set -euo pipefail
cd "$(dirname "$0")/.."
surfaces=("$@"); [ ${#surfaces[@]} -eq 0 ] && surfaces=(web android server ios)
status=0
for s in "${surfaces[@]}"; do
  echo "== i18n-lint: $s"
  case "$s" in
    web)
      (cd chronicle-web && bash scripts/i18n-lint-selftest.sh && ast-grep scan src/modern && { bun run --silent i18n:report es --check | grep -E '^[a-z-]+: ' || { echo 'i18n:report --check failed'; false; }; }) || status=1 ;;
    android)
      (cd chronicle && bash scripts/i18n-lint-selftest.sh && ast-grep scan app/src/main collection-*/src/main) || status=1 ;;
    server)
      (cd chronicle-server && bash scripts/i18n-lint-selftest.sh && ast-grep scan src/main) || status=1 ;;
    ios)
      if [ -f chronicle-ios/lint/i18n/semgrep.yml ]; then
        (cd chronicle-ios && bash scripts/i18n-lint-selftest.sh && semgrep --metrics=off --error --quiet --config lint/i18n/semgrep.yml chronicle ChronicleScreenTimeReport) || status=1
      else
        echo "ios: no rules yet"; fi ;;
    *) echo "unknown surface: $s"; exit 2 ;;
  esac
done
exit $status
