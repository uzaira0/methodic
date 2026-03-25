#!/usr/bin/env bash
# Multi-target autoresearch benchmark for Chronicle
set -uo pipefail
cd "$(dirname "$0")/.."

echo "=== Chronicle Multi-Target Benchmark ==="

# --- Test Pass Count ---
echo "--- Test Pass Count ---"
PASS=0; FAIL=0; SKIP=0
for script in tests/security/smoke-tests.sh tests/security/business-logic-tests.sh tests/security/contract-drift-tests.sh tests/security/api-header-tests.sh tests/security/session-management-tests.sh tests/security/database-security-tests.sh tests/security/container-security-tests.sh tests/security/test-waf.sh; do
  if [ -f "$script" ]; then
    OUT=$(timeout 120 bash "$script" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
    P=$(echo "$OUT" | grep -c '\[PASS\]' || true)
    F=$(echo "$OUT" | grep -c '\[FAIL\]' || true)
    S=$(echo "$OUT" | grep -c '\[SKIP\]' || true)
    PASS=$((PASS + P)); FAIL=$((FAIL + F)); SKIP=$((SKIP + S))
  fi
done
echo "METRIC total_pass=$PASS"
echo "METRIC total_fail=$FAIL"
echo "METRIC total_skip=$SKIP"

# --- Frontend Bundle ---
echo "--- Frontend Bundle ---"
DIST_DIR="chronicle-web/build"
[ ! -d "$DIST_DIR" ] && DIST_DIR="chronicle-web/dist"
if [ -d "$DIST_DIR" ]; then
  KB=$(du -sk "$DIST_DIR" 2>/dev/null | awk '{print $1}')
  echo "METRIC bundle_kb=$KB"
else
  echo "METRIC bundle_kb=0"
fi

# --- Image Sizes ---
echo "--- Image Sizes ---"
BE=$(docker images chronicle-backend:latest --format '{{.Size}}' 2>/dev/null | sed 's/MB//' | sed 's/GB/*1024/' | bc -l 2>/dev/null | cut -d. -f1 || echo "0")
FE=$(docker images chronicle-frontend:latest --format '{{.Size}}' 2>/dev/null | sed 's/MB//' | sed 's/GB/*1024/' | bc -l 2>/dev/null | cut -d. -f1 || echo "0")
echo "METRIC backend_image_mb=$BE"
echo "METRIC frontend_image_mb=$FE"

# --- Backend Memory ---
echo "--- Backend Memory ---"
HEAP=$(docker exec chronicle-backend wget -qO- http://127.0.0.1:40320/prometheus/ 2>/dev/null | grep -m1 'jvm_memory' | awk '{printf "%.3f", $2/1048576}' || echo "0")
[ -z "$HEAP" ] && HEAP="0"
echo "METRIC heap_mb=$HEAP"

# --- API Latency ---
echo "--- API Latency ---"
DOMAIN=$(grep -E '^DOMAIN=' docker/.env 2>/dev/null | cut -d= -f2 || echo "localhost")
P95=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  T=$(curl -sk -o /dev/null -w '%{time_total}' "http://${DOMAIN}/chronicle/v3/edm/entity/type" 2>/dev/null || echo "0")
  MS=$(echo "$T * 1000" | bc -l 2>/dev/null || echo "0")
  P95=$(echo "if($MS > $P95) $MS else $P95" | bc -l 2>/dev/null || echo "$P95")
done
printf "METRIC api_p95_ms=%.2f\n" "$P95"

# --- Backup Duration ---
echo "--- Backup Duration ---"
START=$(date +%s%N)
docker exec chronicle-postgres pg_dump -U $(grep POSTGRES_USER docker/.env 2>/dev/null | cut -d= -f2) $(grep POSTGRES_DB docker/.env 2>/dev/null | cut -d= -f2) > /dev/null 2>&1
END=$(date +%s%N)
MS=$(( (END - START) / 1000000 ))
echo "METRIC backup_ms=$MS"

echo "=== Benchmark Complete ==="
