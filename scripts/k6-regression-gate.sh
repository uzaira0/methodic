#!/usr/bin/env bash
# Compares latest k6 summary against committed baselines.
# Fails if p95 latency increased more than 15%.
set -euo pipefail

baselines="${1:-tests/perf/k6-baselines.json}"
current="${2:-tests/load/k6-summary.json}"

if [ ! -f "$baselines" ]; then
    echo "No baselines at $baselines — skipping regression check."
    exit 0
fi

if [ ! -f "$current" ]; then
    echo "ERROR: k6 summary not found at $current"
    exit 1
fi

threshold="${K6_REGRESSION_THRESHOLD:-1.15}"

failed=false
while IFS= read -r metric; do
    base_p95=$(jq -r ".metrics[\"$metric\"].values[\"p(95)\"] // empty" "$baselines")
    curr_p95=$(jq -r ".metrics[\"$metric\"].values[\"p(95)\"] // empty" "$current")

    if [ -z "$base_p95" ] || [ -z "$curr_p95" ]; then
        continue
    fi

    ratio=$(echo "$curr_p95 / $base_p95" | bc -l 2>/dev/null || echo "0")
    exceeded=$(echo "$ratio > $threshold" | bc -l 2>/dev/null || echo "0")

    if [ "$exceeded" = "1" ]; then
        printf "REGRESSION: %s p95 %.1fms → %.1fms (%.0f%% increase)\n" \
            "$metric" "$base_p95" "$curr_p95" "$(echo "($ratio - 1) * 100" | bc -l)"
        failed=true
    fi
done < <(jq -r '.metrics | keys[] | select(contains("http_req_duration"))' "$baselines" 2>/dev/null)

if [ "$failed" = "true" ]; then
    echo "k6 performance regression detected (>${threshold}x threshold)."
    exit 1
fi

echo "No k6 regressions detected. ✓"
