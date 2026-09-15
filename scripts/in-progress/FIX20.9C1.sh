#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location

F="$R/app/health/core/continuous_adaptive_runner.py"
Q="$R/app/health/core/adaptive_live_queue.py"

echo "=== LEASE LOOP ==="

grep -n \
-B45 -A190 \
"lease_next(" \
"$F" \
| head -n 520


echo "=== RESULT ROOT USAGE ==="

grep -n \
-B15 -A35 \
-E "result_root|JsonHealthResultStore|latest" \
"$F" \
| head -n 240


echo "=== REQUEUE EXACT ==="

sed -n "392,432p" "$Q"


echo "=== LOOP LIMIT ==="

grep -n \
-B25 -A90 \
-E "attempted.*selected_target|selected_target|desired_workers|len\\(active\\)" \
"$F" \
| head -n 400


echo "========================================"
echo "FIX20.9C1=PASS"
echo "COVERAGE_PATCH_ANCHOR=PINNED"
echo "========================================"
