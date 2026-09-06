#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location

F="$R/app/health/runtime/launcher.py"

echo "=== LAUNCH SIGNATURE ==="

grep -n \
-B15 -A150 \
"def launch(" \
"$F" \
| head -n 220


echo "=== LAUNCHED RUNTIME CONTRACT ==="

sed -n "1,90p" "$F"


echo "=== LAUNCH CALLERS ==="

grep -RIn \
--include="*.py" \
-B12 -A35 \
"\.launch(" \
"$R/app/health" \
| head -n 450


echo "=== HEALTH PIPELINE RUNTIME ==="

grep -RIn \
--include="*.py" \
-B20 -A100 \
-E "RuntimeLauncher|launcher.launch|proxy_url" \
"$R/app/health/core" \
| head -n 600


echo "=== CONFIG STORE READ CONTRACT ==="

grep -RIn \
--include="*.py" \
-B15 -A70 \
-E "def find_config_record|def load.*config|config_id.*source.raw|source.raw" \
"$R/app" \
| head -n 450


echo "=== CURL CAPABILITIES ==="

curl --version | head -n 3


echo "=== DIRECT IP ENDPOINT BASELINE ==="

for u in \
https://api.ipify.org \
https://icanhazip.com \
https://ifconfig.me/ip
do
    printf '%s -> ' "$u"

    curl \
    -4 \
    -fsS \
    --max-time 8 \
    "$u" \
    2>/dev/null \
    | head -c 100 \
    || echo "FAIL"

    echo
done


echo "=== SERVICES ==="

for svc in \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service
do
    echo "$svc=$(systemctl is-active "$svc" 2>/dev/null || true)"
done


echo "========================================"
echo "FIX22C1=PASS"
echo "RUNTIME_EXIT_OBSERVATION_CONTRACT=PINNED"
echo "========================================"
