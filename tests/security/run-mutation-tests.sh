#!/usr/bin/env bash
# run-mutation-tests.sh — Run PIT mutation testing on Chronicle security code
# Targets: JwtBlocklist, PaginationDefaults, JwtBlocklistFilter
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORT_DIR="$PROJECT_ROOT/chronicle-server/build/reports/pitest"

echo "========================================"
echo "  PIT Mutation Testing — Security Code"
echo "========================================"
echo ""
echo "Target classes:"
echo "  - com.openlattice.chronicle.authorization.JwtBlocklist"
echo "  - com.openlattice.chronicle.util.PaginationDefaults"
echo "  - com.openlattice.chronicle.filters.JwtBlocklistFilter"
echo ""

cd "$PROJECT_ROOT"
echo "Running ./gradlew :chronicle-server:pitest ..."
echo ""

./gradlew :chronicle-server:pitest "$@"

echo ""
echo "========================================"
echo "  Mutation Testing Complete"
echo "========================================"

# Parse mutation score from XML report if available
XML_REPORT="$REPORT_DIR/mutations.xml"
if [ -f "$XML_REPORT" ]; then
    TOTAL=$(grep -c '<mutation ' "$XML_REPORT" 2>/dev/null || echo 0)
    KILLED=$(grep -c 'status="KILLED"' "$XML_REPORT" 2>/dev/null || echo 0)
    SURVIVED=$(grep -c 'status="SURVIVED"' "$XML_REPORT" 2>/dev/null || echo 0)
    NO_COVERAGE=$(grep -c 'status="NO_COVERAGE"' "$XML_REPORT" 2>/dev/null || echo 0)

    if [ "$TOTAL" -gt 0 ]; then
        SCORE=$(( KILLED * 100 / TOTAL ))
        echo ""
        echo "Mutation Score: ${SCORE}% (${KILLED}/${TOTAL} mutants killed)"
        echo "  Killed:      $KILLED"
        echo "  Survived:    $SURVIVED"
        echo "  No Coverage: $NO_COVERAGE"
    fi
fi

echo ""
echo "Reports:"
echo "  HTML: $REPORT_DIR/index.html"
echo "  XML:  $REPORT_DIR/mutations.xml"
