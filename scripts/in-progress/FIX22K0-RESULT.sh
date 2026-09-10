#!/usr/bin/env bash
set -Eeuo pipefail

D=/var/log/config-location/chatgpt/stages

echo "=== FIND EXACT K0 LOG ==="

F=$(
    find "$D" \
    -maxdepth 1 \
    -type f \
    -name 'FIX22K0-HEALTH-COUNTRY-INTEGRATION-CONTRACT-*.log' \
    -printf '%T@ %p\n' \
    | sort -nr \
    | head -n1 \
    | cut -d' ' -f2-
)

echo "LOG=$F"

test -n "$F"
test -f "$F"

echo
echo "=== K0 RESULT ==="

grep -E \
'FIX22K0=|DEVLOG_RESULT=|EXIT_CODE=|HEALTH_PASS_BOUNDARY=|UPLOAD_DOWNLOAD_BOUNDARY=|RUNTIME_OWNERSHIP=|RUNTIME_CLEANUP=|HEALTH_COMMIT_POINT=|ADAPTIVE_CONTROLLER=|XRAY_WARNING_BOUNDARY=|PRODUCTION_CHANGED=' \
"$F" || true

echo
echo "=== K0 LAST 180 LINES ==="

tail -n 180 "$F"

echo
echo "=== SERVICES ==="

for svc in \
config-location-country-worker.service \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done

echo
echo "========================================"
echo "FIX22K0_RESULT_REFRESH=PASS"
echo "========================================"
