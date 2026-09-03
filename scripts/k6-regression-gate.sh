#!/usr/bin/env bash
# Compares latest k6 summary against committed baselines.
# Fails if p95 latency exceeds the committed baseline/budget by more than 15%.
set -euo pipefail

baselines="${1:-tests/perf/k6-baselines.json}"
current="${2:-tests/load/k6-summary.json}"

if [ ! -f "$baselines" ]; then
    echo "ERROR: required k6 baseline/budget not found at $baselines"
    exit 1
fi

if [ ! -f "$current" ]; then
    echo "ERROR: k6 summary not found at $current"
    exit 1
fi

threshold="${K6_REGRESSION_THRESHOLD:-1.15}"

has_real_baselines=$(jq -r '[.metrics[].values["p(95)"] // 0 | select(. > 0)] | length > 0' "$baselines")
if [ "$has_real_baselines" != "true" ]; then
    echo "ERROR: k6 baseline/budget contains no positive p95 values"
    exit 1
fi

failed=false
while IFS= read -r metric; do
    base_p95=$(jq -r ".metrics[\"$metric\"].values[\"p(95)\"] // empty" "$baselines")
    curr_p95=$(jq -r ".metrics[\"$metric\"].values[\"p(95)\"] // empty" "$current")

    if [ -z "$base_p95" ] || [ -z "$curr_p95" ]; then
        continue
    fi

    ratio=$(jq -nr --argjson current "$curr_p95" --argjson base "$base_p95" '$current / $base')
    exceeded=$(jq -nr --argjson ratio "$ratio" --argjson threshold "$threshold" '$ratio > $threshold')

    if [ "$exceeded" = "true" ]; then
        increase=$(jq -nr --argjson ratio "$ratio" '($ratio - 1) * 100 | round')
        printf "REGRESSION: %s p95 %.1fms → %.1fms (%.0f%% increase)\n" \
            "$metric" "$base_p95" "$curr_p95" "$increase"
        failed=true
    fi
done < <(jq -r '.metrics | keys[] | select(contains("http_req_duration"))' "$baselines")

if [ "$failed" = "true" ]; then
    echo "k6 performance regression detected (>${threshold}x threshold)."
    exit 1
fi

echo "No k6 regressions detected. ✓"
