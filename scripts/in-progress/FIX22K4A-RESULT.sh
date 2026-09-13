#!/usr/bin/env bash
set -Eeuo pipefail

D=/var/log/config-location/chatgpt/stages

F=$(
    find "$D" \
    -maxdepth 1 \
    -type f \
    -name 'FIX22K4A-GEO-CACHE-SINGLEFLIGHT-CONTRACT-*.log' \
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
'FIX22K4A=|MODE=|PRODUCTION_CHANGED=|NEXT=|EXIT_CODE=|DEVLOG_RESULT=' \
"$F" || true


echo
echo "=== GEO MODULES ==="

grep -nE \
'geo_consensus|geo_provider|provider|lookup|rdap|asn|ipapi|ipinfo|ipwho|country.is' \
"$F" \
| head -n 450 || true


echo
echo "=== GEO FUNCTIONS / CALLERS ==="

grep -nE \
'def .*geo|def .*lookup|GeoResult|GeoEvidence|resolve|consensus|lookup_' \
"$F" \
| tail -n 450 || true


echo
echo "=== EXISTING CACHE ==="

grep -nEi \
'cache|ttl|expires|single.flight|flock|lock|memo' \
"$F" \
| tail -n 300 || true


echo
echo "=== EXIT-IP REUSE ==="

grep -E \
'HANDOFF_WITH_IP=|UNIQUE_EXIT_IPS=|DUPLICATE_LOOKUPS_AVOIDABLE=|TOP_REUSED_IPS=' \
-A25 \
"$F" || true


echo
echo "=== QUEUE ==="

grep -E '^QUEUE=' \
"$F" || true


echo
echo "=== SERVICES ==="

for svc in \
config-location-country-worker.service \
config-location-health-adaptive.service \
config-location-fetcher.service
do

    X=$(
        systemctl is-active \
        "$svc" 2>/dev/null || true
    )

    echo "$svc=$X"

    test "$X" = active
done


echo
echo "========================================"
echo "FIX22K4A_RESULT_REFRESH=PASS"
echo "========================================"
