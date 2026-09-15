#!/usr/bin/env bash
set -Eeuo pipefail

D=/var/log/config-location/chatgpt/stages

F=$(
    find "$D" \
    -maxdepth 1 \
    -type f \
    -name 'FIX22K1C6-ROLLBACK-AND-RESULT-COMMIT-PIN-*.log' \
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
'FIX22K1C6=|K1C5_ROLLBACK=|LIFECYCLE_RESTORED=|EVENT_BUS_CORE=|HEALTH_PRODUCTION=|NEXT=|DEVLOG_RESULT=|EXIT_CODE=' \
"$F" || true

echo
echo "=== WRITER FILES ==="

grep -E \
'^/opt/config-location/app/health/.*\.py|health-results/latest|RESULT_DIR' \
"$F" \
| grep -E \
'atomic_json|write_text|RESULT_DIR|health-results/latest' \
| tail -n 120 || true

echo
echo "=== SAMPLE HEALTH SCHEMA ==="

grep -E \
'^(FILE|KEYS|STATE|HEALTH_QUALIFIED|DOWNLOAD_VERIFIED|UPLOAD_VERIFIED|DECISION|METADATA_HEALTH_DECISION|STARTED|FINISHED)=' \
"$F" \
| tail -n 40 || true

echo
echo "=== ROLLBACK VERIFY ==="

! grep -q \
'FIX22K1 HEALTH_COUNTRY_EVENT_HOOK' \
/opt/config-location/app/health/lifecycle/consecutive.py

echo "FAILED_PATCH_PRESENT=NO"

echo
echo "=== SERVICES ==="

for svc in \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-country-worker.service \
config-location-fetcher.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done

echo
echo "========================================"
echo "FIX22K1C6_RESULT_REFRESH=PASS"
echo "========================================"
