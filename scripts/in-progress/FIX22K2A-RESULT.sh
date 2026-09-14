#!/usr/bin/env bash
set -Eeuo pipefail

D=/var/log/config-location/chatgpt/stages

F=$(
    find "$D" \
    -maxdepth 1 \
    -type f \
    -name 'FIX22K2A-SAME-RUNTIME-CONTRACT-PIN-*.log' \
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
'FIX22K2A=|MODE=|PRODUCTION_CHANGED=|NEXT=|EXIT_CODE=|DEVLOG_RESULT=' \
"$F" || true

echo
echo "=== TARGET FUNCTION / RUNTIME WINDOW ==="

grep -nE \
'TARGET_FUNCTION=|LINES=|apply_health_decision|runtime.stop|proxy_url|download_verified|upload_verified' \
"$F" \
| tail -n 260 || true

echo
echo "=== EXISTING COUNTRY FAST PROBES ==="

grep -nE \
'observe_exit_ip|socks5h|checkip|exit_ip|proxy_url' \
"$F" \
| tail -n 260 || true

echo
echo "=== COUNTRY SAVE / PIPELINE API ==="

grep -nE \
'save_country_result|confirmed_stable|pending_confirmation|process_country' \
"$F" \
| tail -n 220 || true

echo
echo "=== QUEUE ==="

grep -E '^QUEUE=' "$F" || true

echo
echo "=== SERVICES ==="

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
echo "FIX22K2A_RESULT_REFRESH=PASS"
echo "========================================"
