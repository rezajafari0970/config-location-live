#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
F="$R/app/health/lifecycle/consecutive.py"

echo "=== CONSECUTIVE EXACT CONTRACT ==="

nl -ba "$F" \
| sed -n '130,230p'

echo
echo "=== IMPORTS ==="

nl -ba "$F" \
| sed -n '1,80p'

echo
echo "=== CALLERS ==="

grep -RIn \
--include='*.py' \
-B15 -A30 \
-E \
'consecutive|update_consecutive|health_qualified' \
"$R/app/health" \
| head -n 700 || true

echo
echo "=== SERVICES ==="

for svc in \
config-location-country-worker.service \
config-location-health-adaptive.service \
config-location-fetcher.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done

echo
echo "========================================"
echo "FIX22K1C2=PASS"
echo "PRODUCTION_CHANGED=NO"
echo "========================================"
