#!/usr/bin/env bash
# =============================================================================
# Parallel Security Test Runner
# =============================================================================
# Runs all 8 security test scripts concurrently and aggregates results.
#
# Usage:
#   ./tests/security/run-tests-parallel.sh
#
# Exit code: 0 if all pass, 1 if any test script failed.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load environment for scripts that need BACKEND_URL, DOMAIN, etc.
if [ -f "$PROJECT_ROOT/docker/.env" ]; then
  DOMAIN=$(grep '^DOMAIN=' "$PROJECT_ROOT/docker/.env" 2>/dev/null | cut -d= -f2) || true
  export DOMAIN
fi

BACKEND_URL="${BACKEND_URL:-}"
if [ -z "$BACKEND_URL" ]; then
  if curl -sf http://localhost:40320/chronicle/prometheus/ &>/dev/null; then
    BACKEND_URL="http://localhost:40320"
  elif [ -n "${DOMAIN:-}" ] && curl -sf "http://${DOMAIN}/chronicle/prometheus/" &>/dev/null; then
    BACKEND_URL="http://${DOMAIN}"
  fi
fi
export BACKEND_URL

# All 8 test scripts
SCRIPTS=(
  smoke-tests.sh
  business-logic-tests.sh
  contract-drift-tests.sh
  api-header-tests.sh
  session-management-tests.sh
  database-security-tests.sh
  container-security-tests.sh
  test-waf.sh
)

# Create temp dir for output files
TMPDIR_PAR=$(mktemp -d)
trap 'rm -rf "$TMPDIR_PAR"' EXIT

# Clear CrowdSec bans once before parallel launch (prevents 429s from concurrent requests)
if [ -f "$SCRIPT_DIR/lib-test-helpers.sh" ]; then
  source "$SCRIPT_DIR/lib-test-helpers.sh"
  setup_crowdsec_whitelist
fi

WALL_START=$(date +%s)

echo ""
echo "======================================================="
echo "  Parallel Security Test Runner — launching ${#SCRIPTS[@]} scripts"
echo "======================================================="
echo ""

# Launch all scripts in background
PIDS=()
for script in "${SCRIPTS[@]}"; do
  script_path="$SCRIPT_DIR/$script"
  base="${script%.sh}"
  outfile="$TMPDIR_PAR/${base}.out"
  timefile="$TMPDIR_PAR/${base}.time"

  if [ ! -f "$script_path" ]; then
    echo "SKIP" > "$TMPDIR_PAR/${base}.status"
    echo "Script not found: $script_path" > "$outfile"
    echo "0" > "$timefile"
    continue
  fi

  (
    t_start=$(date +%s)
    exit_code=0
    BACKEND_URL="$BACKEND_URL" BASE_URL="$BACKEND_URL" \
      bash "$script_path" > "$outfile" 2>&1 || exit_code=$?
    t_end=$(date +%s)
    echo "$((t_end - t_start))" > "$timefile"
    if [ "$exit_code" -eq 0 ]; then
      echo "OK" > "$TMPDIR_PAR/${base}.status"
    else
      echo "FAILED" > "$TMPDIR_PAR/${base}.status"
    fi
  ) &
  PIDS+=($!)
  echo "  Started: $script (PID $!)"
done

echo ""
echo "  Waiting for all scripts to finish..."
echo ""

# Wait for all background jobs
for pid in "${PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
done

WALL_END=$(date +%s)
WALL_ELAPSED=$((WALL_END - WALL_START))

# Aggregate results
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
ANY_FAILED=0

# Print per-script summary table
printf "\n"
printf "%-30s %-8s %6s %6s %6s %8s\n" "SCRIPT" "STATUS" "PASS" "FAIL" "SKIP" "TIME"
printf "%-30s %-8s %6s %6s %6s %8s\n" "------------------------------" "--------" "------" "------" "------" "--------"

for script in "${SCRIPTS[@]}"; do
  base="${script%.sh}"
  outfile="$TMPDIR_PAR/${base}.out"
  timefile="$TMPDIR_PAR/${base}.time"
  statusfile="$TMPDIR_PAR/${base}.status"

  status=$(cat "$statusfile" 2>/dev/null || echo "UNKNOWN")
  elapsed=$(cat "$timefile" 2>/dev/null || echo "?")

  # Count PASS/FAIL/SKIP from script output
  p=0; f=0; s=0
  if [ -f "$outfile" ]; then
    p=$(grep -c '\[PASS\]' "$outfile" 2>/dev/null || true)
    f=$(grep -c '\[FAIL\]' "$outfile" 2>/dev/null || true)
    s=$(grep -c '\[SKIP\]' "$outfile" 2>/dev/null || true)
  fi

  TOTAL_PASS=$((TOTAL_PASS + p))
  TOTAL_FAIL=$((TOTAL_FAIL + f))
  TOTAL_SKIP=$((TOTAL_SKIP + s))

  if [ "$status" = "FAILED" ]; then
    ANY_FAILED=1
    status_display="\033[1;31mFAILED\033[0m"
  elif [ "$status" = "SKIP" ]; then
    status_display="\033[1;33mSKIP\033[0m"
  else
    status_display="\033[1;32mOK\033[0m"
  fi

  printf "%-30s " "$script"
  printf "${status_display}"
  printf "   %6d %6d %6d %7ss\n" "$p" "$f" "$s" "$elapsed"
done

# Print overall summary
echo ""
echo "======================================================="
echo "  PARALLEL TEST SUMMARY"
echo "======================================================="
echo -e "  \033[32mPassed:\033[0m  $TOTAL_PASS"
echo -e "  \033[31mFailed:\033[0m  $TOTAL_FAIL"
echo -e "  \033[33mSkipped:\033[0m $TOTAL_SKIP"
echo "  Wall-clock time: ${WALL_ELAPSED}s"
echo "======================================================="
echo ""

# Print detailed output for failed scripts
if [ "$ANY_FAILED" -eq 1 ] || [ "$TOTAL_FAIL" -gt 0 ]; then
  echo "--- Failed script output ---"
  for script in "${SCRIPTS[@]}"; do
    base="${script%.sh}"
    status=$(cat "$TMPDIR_PAR/${base}.status" 2>/dev/null || echo "UNKNOWN")
    if [ "$status" = "FAILED" ] || grep -q '\[FAIL\]' "$TMPDIR_PAR/${base}.out" 2>/dev/null; then
      echo ""
      echo "=== $script ==="
      cat "$TMPDIR_PAR/${base}.out" 2>/dev/null
    fi
  done
  echo ""
  exit 1
fi

exit 0
