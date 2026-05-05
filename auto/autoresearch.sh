#!/usr/bin/env bash
# Multi-target autoresearch benchmark for Chronicle
# Runs all measurable metrics and outputs METRIC lines
set -uo pipefail
cd "$(dirname "$0")/.."

echo "=== Chronicle Multi-Target Benchmark ==="
echo ""

# --- 1. Test pass count ---
echo "--- Test Pass Count ---"
OUT=$(DOMAIN=cnrc-deni-p001.cnrc.bcm.edu timeout 600 bash tests/security/run-all-security.sh 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
PASS=$(echo "$OUT" | grep -c '\[PASS\]' || true)
FAIL=$(echo "$OUT" | grep -c '\[FAIL\]' || true)
SKIP=$(echo "$OUT" | grep -c '\[SKIP\]' || true)
echo "METRIC total_pass=${PASS}"
echo "METRIC total_fail=${FAIL}"
echo "METRIC total_skip=${SKIP}"

# --- 2. Frontend bundle size ---
echo "--- Frontend Bundle ---"
if [ -d chronicle-web/dist ]; then
  BUNDLE_KB=$(du -sk chronicle-web/dist/ | cut -f1)
elif [ -d chronicle-web/build ]; then
  BUNDLE_KB=$(du -sk chronicle-web/build/ | cut -f1)
else
  BUNDLE_KB=0
fi
echo "METRIC bundle_kb=${BUNDLE_KB}"

# --- 3. Docker image sizes ---
echo "--- Image Sizes ---"
BE_SIZE=$(docker image inspect chronicle-backend:latest --format '{{.Size}}' 2>/dev/null || echo "0")
FE_SIZE=$(docker image inspect chronicle-frontend:latest --format '{{.Size}}' 2>/dev/null || echo "0")
BE_MB=$((BE_SIZE / 1048576))
FE_MB=$((FE_SIZE / 1048576))
echo "METRIC backend_image_mb=${BE_MB}"
echo "METRIC frontend_image_mb=${FE_MB}"

# --- 4. Backend memory usage ---
echo "--- Backend Memory ---"
HEAP_MB=$(docker exec chronicle-backend curl -sf http://localhost:40320/chronicle/prometheus/ 2>/dev/null | grep -oP 'runtime_totalMemory\{[^}]*\} \K[0-9.]+' || echo "0")
if [ "$HEAP_MB" = "0" ]; then
  # Fallback: get from docker stats
  HEAP_MB=$(docker stats chronicle-backend --no-stream --format '{{.MemUsage}}' 2>/dev/null | grep -oP '^\K[0-9.]+' || echo "0")
fi
echo "METRIC heap_mb=${HEAP_MB}"

# --- 5. API latency (quick k6 check) ---
echo "--- API Latency ---"
if command -v k6 &>/dev/null; then
  K6_OUT=$(k6 run --quiet --no-color --env BASE_URL=http://cnrc-deni-p001.cnrc.bcm.edu - 2>&1 <<'K6SCRIPT'
import http from 'k6/http';
import { sleep } from 'k6';
export const options = { vus: 5, duration: '10s', thresholds: { 'http_req_duration{scenario:default}': ['p(95)<2000'] } };
export default function() {
  http.get(`${__ENV.BASE_URL}/chronicle/v3/auth/session`);
  sleep(0.1);
}
K6SCRIPT
  )
  P95=$(echo "$K6_OUT" | grep -oP 'p\(95\)=\K[0-9.]+' | head -1 || echo "0")
  echo "METRIC api_p95_ms=${P95}"
else
  echo "METRIC api_p95_ms=0"
fi

# --- 6. Backup duration ---
echo "--- Backup Duration ---"
if [ -x docker/backup-chronicle.sh ] && docker ps --format '{{.Names}}' | grep -q chronicle-postgres; then
  BACKUP_START=$(date +%s%3N)
  timeout 120 bash docker/backup-chronicle.sh 2>/dev/null
  BACKUP_END=$(date +%s%3N)
  BACKUP_MS=$((BACKUP_END - BACKUP_START))
  echo "METRIC backup_ms=${BACKUP_MS}"
else
  echo "METRIC backup_ms=0"
fi

echo ""
echo "=== Benchmark Complete ==="
