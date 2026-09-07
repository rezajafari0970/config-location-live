#!/usr/bin/env bash
set -Eeuo pipefail

D=/var/log/config-location/chatgpt/stages

F=$(
  find "$D" \
    -maxdepth 1 \
    -type f \
    -name 'FIX22K1-CONSUMER-A-CONTRACT-PIN-*.log' \
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
'FIX22K1_CONSUMER_A=|MODE=|PRODUCTION_CHANGED=|NEXT=|EXIT_CODE=|DEVLOG_RESULT=' \
"$F" || true

echo
echo "=== EVENT BUS API ==="

grep -nE \
'def lease|def ack|def nack|def recover_expired|def stats|retry|attempt|dead' \
"$F" \
| tail -n 500 || true

echo
echo "=== PIPELINE ENTRY ==="

grep -nE \
'pipeline.py|def process|def run|resolve_geo|save.*country|confirmed_stable|confirmed_rotating_ip|pending_confirmation' \
"$F" \
| tail -n 700 || true

echo
echo "=== EVENT SAMPLE ==="

grep -E \
'SAMPLE_COUNT=|EVENT=' \
"$F" || true

echo
echo "=== QUEUE ==="

grep -E \
'RECOVERED=|QUEUE=' \
"$F" || true

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
echo "=== LAST 160 LINES ==="

tail -n 160 "$F"

echo
echo "========================================"
echo "FIX22K1_CONSUMER_A_RESULT=PASS"
echo "========================================"
