#!/usr/bin/env bash
set -Eeuo pipefail

D=/var/log/config-location/chatgpt/stages

echo "=== FIND K1C AUDIT ==="

F=$(
    find "$D" \
    -maxdepth 1 \
    -type f \
    -name 'FIX22K1C-HEALTH-EVENT-HOOK-AUDIT-*.log' \
    -printf '%T@ %p\n' \
    | sort -nr \
    | head -n1 \
    | cut -d' ' -f2-
)

echo "LOG=$F"

test -n "$F"
test -f "$F"

echo
echo "=== IMPORTANT MATCHES ==="

grep -nE \
'health_qualified|real_transfer_health|health-results|runtime.stop|finally:|return result|return.*health' \
"$F" \
| tail -n 250 || true

echo
echo "=== CANDIDATE FILES / END ==="

tail -n 220 "$F"

echo
echo "=== SERVICES ==="

for svc in \
config-location-country-worker.service \
config-location-fetcher.service \
config-location-health-adaptive.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done

echo
echo "========================================"
echo "FIX22K1C_RESULT_REFRESH=PASS"
echo "PRODUCTION_CHANGED=NO"
echo "========================================"
