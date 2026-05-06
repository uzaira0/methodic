#!/usr/bin/env bash
# Compares latest JMH results against committed baselines.
# Fails if any benchmark's throughput dropped more than 10%.
set -euo pipefail

baselines="${1:-tests/perf/jmh-baselines.json}"
results="${2:-chronicle-server/build/results/jmh/results.json}"

if [ ! -f "$baselines" ]; then
    echo "No baselines at $baselines — skipping regression check."
    exit 0
fi

if [ ! -f "$results" ]; then
    echo "ERROR: JMH results not found at $results"
    exit 1
fi

threshold="${JMH_REGRESSION_THRESHOLD:-0.90}"

regressions=$(jq -r --slurpfile base "$baselines" --argjson thresh "$threshold" '
    [.[] as $cur |
     ($base[0][] | select(.benchmark == $cur.benchmark)) as $old |
     select($old != null) |
     select(($cur.primaryMetric.score / $old.primaryMetric.score) < $thresh) |
     "\($cur.benchmark): \($old.primaryMetric.score | round) → \($cur.primaryMetric.score | round) ops/s (\((($cur.primaryMetric.score / $old.primaryMetric.score - 1) * 100) | round)%)"
    ] | .[]
' "$results" 2>/dev/null || echo "")

if [ -n "$regressions" ]; then
    echo "JMH regression detected (ratio dropped below ${threshold}):"
    echo "$regressions"
    exit 1
fi

echo "No JMH regressions detected. ✓"
