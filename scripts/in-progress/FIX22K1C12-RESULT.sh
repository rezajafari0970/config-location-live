#!/usr/bin/env bash
set -Eeuo pipefail

D=/var/log/config-location/chatgpt/stages

F=$(
    find "$D" \
    -maxdepth 1 \
    -type f \
    -name 'FIX22K1C12-ACTIVE-HEALTH-CALLGRAPH-*.log' \
    -printf '%T@ %p\n' \
    | sort -nr \
    | head -n1 \
    | cut -d' ' -f2-
)

echo "LOG=$F"

test -n "$F"
test -f "$F"

echo
echo "=== RESULT ==="

grep -E \
'FIX22K1C12=|MODE=|PRODUCTION_CHANGED=|EXIT_CODE=|DEVLOG_RESULT=' \
"$F" || true

echo
echo "=== ACTIVE SERVICE ==="

grep -E \
'ExecStart=|MAIN_PID=|CMDLINE=|EXE=|CWD=|EXECSTART=' \
"$F" \
| head -n 80 || true

echo
echo "=== ACTIVE RUNNER / SAVE PATH ==="

grep -nE \
'continuous_adaptive_runner|adaptive_runner|always_on_adaptive|production_scheduler|JsonHealthResultStore|ResultStore|result_store.save|\.save\(.*result|run_job_with_retry|run_health_job' \
"$F" \
| tail -n 350 || true

echo
echo "=== PRODUCTION SCHEDULER CALLERS ==="

grep -nE \
'production_scheduler|run_production_scheduler_once' \
"$F" \
| tail -n 100 || true

echo
echo "=== RECENT WRITES ==="

grep -E \
'RESULTS_LAST_120S=' \
"$F" || true

echo
echo "=== CURRENT SERVICES ==="

for svc in \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-fetcher.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done

echo
echo "========================================"
echo "FIX22K1C12_RESULT_REFRESH=PASS"
echo "========================================"
