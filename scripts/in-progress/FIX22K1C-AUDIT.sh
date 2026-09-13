#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location

echo "=== EXACT HEALTH QUALIFIED WRITES ==="

grep -RIn \
--include='*.py' \
-B35 -A80 \
-E \
'health_qualified.*True|health_qualified.*=|["'\'']health_qualified["'\'']|real_transfer_health' \
"$R/app/health" \
| head -n 1000 || true

echo
echo "=== EXACT HEALTH LATEST WRITES ==="

grep -RIn \
--include='*.py' \
-B35 -A100 \
-E \
'/health-results/latest|health-results.*latest|HEALTH.*LATEST|latest.*health|save.*result|atomic.*result' \
"$R/app/health" \
| head -n 1200 || true

echo
echo "=== RETURN / FINALLY AROUND PIPELINE ==="

grep -RIn \
--include='*.py' \
-B50 -A120 \
-E \
'return.*health|return result|finally:|runtime.stop|cleanup' \
"$R/app/health/core" \
| head -n 1500 || true

echo
echo "=== CANDIDATE FILES ==="

grep -RIl \
--include='*.py' \
-E \
'health_qualified|real_transfer_health' \
"$R/app/health" \
| sort

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
echo "FIX22K1C_AUDIT=PASS"
echo "PRODUCTION_CHANGED=NO"
echo "========================================"
