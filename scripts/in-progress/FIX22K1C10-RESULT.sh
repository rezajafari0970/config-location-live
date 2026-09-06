#!/usr/bin/env bash
set -Eeuo pipefail

D=/var/log/config-location/chatgpt/stages

F=$(
    find "$D" \
    -maxdepth 1 \
    -type f \
    -name 'FIX22K1C10-RESULTSTORE-CANONICAL-CONTRACT-*.log' \
    -printf '%T@ %p\n' \
    | sort -nr \
    | head -n1 \
    | cut -d' ' -f2-
)

echo "LOG=$F"

test -n "$F"
test -f "$F"

echo
echo "=== STAGE RESULT ==="

grep -E \
'FIX22K1C10=|PRODUCTION_CHANGED=|NEXT=|EXIT_CODE=|DEVLOG_RESULT=' \
"$F" || true

echo
echo "=== RESULTSTORE CONTRACT ==="

grep -nE \
'class ResultStore|def save|def load|def get|def read|to_dict|asdict|result_root|latest|path|json' \
"$F" \
| tail -n 300 || true

echo
echo "=== HEALTHRESULT CONTRACT ==="

grep -nE \
'class HealthResult|def to_dict|asdict|metadata|download_verified|upload_verified|xray_started|job_id' \
"$F" \
| tail -n 260 || true

echo
echo "=== LAST 180 LINES ==="

tail -n 180 "$F"

echo
echo "=== CURRENT SAFETY ==="

grep -n \
'FIX22K1 RESULT_STORE_EVENT' \
/opt/config-location/app/health/core/production_scheduler.py \
|| true

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
echo "FIX22K1C10_RESULT_REFRESH=PASS"
echo "========================================"
