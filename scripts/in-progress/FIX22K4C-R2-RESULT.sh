#!/usr/bin/env bash
set -Eeuo pipefail

D=/var/log/config-location/chatgpt/stages

F=$(
    find "$D" \
    -maxdepth 1 \
    -type f \
    -name 'FIX22K4C-R2-PRODUCTION-SINGLEFLIGHT-VERIFY-*.log' \
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
'FIX22K4C_R2=|FIX22K4=|GEO_CACHE=|SINGLEFLIGHT=|CACHE_TTL=|PER_IP_LOCK=|DOUBLE_CHECK_AFTER_LOCK=|CROSS_PROCESS=|ATOMIC_WRITE=|NEXT=|EXIT_CODE=|DEVLOG_RESULT=' \
"$F" || true

echo
echo "=== METRICS ==="

grep -E \
'REAL_METRIC_ROWS=|ROWS=|ROLES=|CACHE_HITS=|CACHE_HIT_RATE=|OWNERS=|WAITERS=|DIRECT_HITS=|UNEXPECTED=|K4_PRODUCTION_METRICS=' \
"$F" || true

echo
echo "=== CACHE ==="

grep -E \
'CACHE_VALID=|CACHE_INVALID=|CACHE_INTEGRITY=|CROSS_PROCESS_SINGLEFLIGHT=' \
"$F" || true

echo
echo "=== QUEUE ==="

grep -E '^QUEUE=' "$F" || true

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
echo "=== LAST 120 LINES ==="

tail -n 120 "$F"

echo
echo "========================================"
echo "FIX22K4C_R2_RESULT_REFRESH=PASS"
echo "========================================"
