#!/usr/bin/env bash
set -euo pipefail

# SQL Injection Audit Scanner
# Uses semgrep custom rules + grep-based fallback to detect SQL injection risks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RULES_FILE="$PROJECT_ROOT/tests/security/rules/sql-injection.yaml"
REPORTS_DIR="$PROJECT_ROOT/tests/security/reports"
SARIF_OUTPUT="$REPORTS_DIR/sql-injection.sarif"

CRITICAL_FINDINGS=0
GREP_FINDINGS=0

# Ensure reports directory exists
mkdir -p "$REPORTS_DIR"

# ─────────────────────────────────────────────
# 1. Semgrep scan
# ─────────────────────────────────────────────

SEMGREP_AVAILABLE=true
if ! command -v semgrep &>/dev/null; then
    echo "WARNING: semgrep is not installed. Skipping semgrep scan."
    echo "  Install with: pip install semgrep"
    SEMGREP_AVAILABLE=false
fi

SCAN_TARGETS=()
for dir in chronicle-server/src rhizome/src chronicle-api/src; do
    target="$PROJECT_ROOT/$dir"
    if [[ -d "$target" ]]; then
        SCAN_TARGETS+=("$target")
    else
        echo "NOTE: $dir not found, skipping."
    fi
done

if $SEMGREP_AVAILABLE && [[ ${#SCAN_TARGETS[@]} -gt 0 ]]; then
    echo "============================================"
    echo "  Semgrep SQL Injection Scan"
    echo "============================================"
    echo ""

    SEMGREP_EXIT=0
    semgrep \
        --config "$RULES_FILE" \
        --sarif \
        --output "$SARIF_OUTPUT" \
        --exclude '**/test/**' \
        "${SCAN_TARGETS[@]}" || SEMGREP_EXIT=$?

    if [[ $SEMGREP_EXIT -eq 0 ]]; then
        echo "Semgrep scan complete — no findings."
    elif [[ $SEMGREP_EXIT -eq 1 ]]; then
        echo "Semgrep scan complete — findings detected (see SARIF report)."
        CRITICAL_FINDINGS=1
    else
        echo "WARNING: semgrep exited with code $SEMGREP_EXIT."
    fi

    echo "SARIF report: $SARIF_OUTPUT"
    echo ""
else
    if $SEMGREP_AVAILABLE; then
        echo "No scan targets found. Skipping semgrep scan."
    fi
fi

# ─────────────────────────────────────────────
# 2. Grep-based fallback scan
# ─────────────────────────────────────────────

echo "============================================"
echo "  Grep Fallback SQL Injection Scan"
echo "============================================"
echo ""

# Build list of source files (java + kotlin), excluding test dirs
SOURCE_FILES=()
for dir in "${SCAN_TARGETS[@]}"; do
    while IFS= read -r -d '' f; do
        SOURCE_FILES+=("$f")
    done < <(find "$dir" \( -name '*.java' -o -name '*.kt' \) \
        -not -path '*/test/*' -not -path '*/tests/*' -print0 2>/dev/null)
done

if [[ ${#SOURCE_FILES[@]} -eq 0 ]]; then
    echo "No source files found for grep scan."
else
    # 2a. String concatenation in SQL
    echo "--- String concatenation in SQL ---"
    CONCAT_HITS=$(grep -n -E '"(SELECT|INSERT|UPDATE|DELETE|WHERE|FROM|JOIN|SET|VALUES|ORDER BY|GROUP BY|HAVING) "\s*\+' \
        "${SOURCE_FILES[@]}" 2>/dev/null || true)
    if [[ -n "$CONCAT_HITS" ]]; then
        echo "$CONCAT_HITS"
        GREP_FINDINGS=$((GREP_FINDINGS + $(echo "$CONCAT_HITS" | wc -l)))
        CRITICAL_FINDINGS=1
    else
        echo "  No findings."
    fi
    echo ""

    # 2b. String.format() near SQL keywords
    echo "--- String.format() with SQL keywords ---"
    FORMAT_HITS=$(grep -n -E 'String\.format\(\s*"[^"]*\b(SELECT|INSERT|UPDATE|DELETE|WHERE|FROM)\b' \
        "${SOURCE_FILES[@]}" 2>/dev/null || true)
    if [[ -n "$FORMAT_HITS" ]]; then
        echo "$FORMAT_HITS"
        GREP_FINDINGS=$((GREP_FINDINGS + $(echo "$FORMAT_HITS" | wc -l)))
        CRITICAL_FINDINGS=1
    else
        echo "  No findings."
    fi
    echo ""

    # 2c. createStatement() usage
    echo "--- createStatement() usage ---"
    STMT_HITS=$(grep -n -E '\.createStatement\s*\(' \
        "${SOURCE_FILES[@]}" 2>/dev/null || true)
    if [[ -n "$STMT_HITS" ]]; then
        echo "$STMT_HITS"
        GREP_FINDINGS=$((GREP_FINDINGS + $(echo "$STMT_HITS" | wc -l)))
    else
        echo "  No findings."
    fi
    echo ""

    # 2d. Raw Statement.execute() without PreparedStatement
    echo "--- Raw Statement.execute() ---"
    EXEC_HITS=$(grep -n -E '\bStatement\b.*\.execute(Query|Update)?\s*\(' \
        "${SOURCE_FILES[@]}" 2>/dev/null || true)
    # Filter out PreparedStatement references
    EXEC_HITS=$(echo "$EXEC_HITS" | grep -v 'PreparedStatement' || true)
    if [[ -n "$EXEC_HITS" ]]; then
        echo "$EXEC_HITS"
        GREP_FINDINGS=$((GREP_FINDINGS + $(echo "$EXEC_HITS" | wc -l)))
    else
        echo "  No findings."
    fi
    echo ""
fi

# ─────────────────────────────────────────────
# 3. Summary
# ─────────────────────────────────────────────

echo "============================================"
echo "  Summary"
echo "============================================"
echo "  Grep findings:    $GREP_FINDINGS"
if $SEMGREP_AVAILABLE; then
    echo "  Semgrep SARIF:    $SARIF_OUTPUT"
fi
echo ""

if [[ $CRITICAL_FINDINGS -ne 0 ]]; then
    echo "RESULT: CRITICAL findings detected. Review output above."
    exit 1
else
    echo "RESULT: No critical SQL injection risks found."
    exit 0
fi
