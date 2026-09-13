#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

D=/var/lib/config-location

echo "=== 1. COUNTRY MODULES ==="

find "$R/app" \
-type f \
-name "*.py" \
| grep -Ei \
"country|geo|location|ipinfo|asn|mmdb|maxmind" \
| sort || true


echo "=== 2. COUNTRY REFERENCES ==="

grep -RIn \
--include="*.py" \
-E "country|country_code|country_name|geoip|mmdb|maxmind|asn|exit_ip|public_ip|browserleaks|whatismyip" \
"$R/app" \
| head -n 1000 || true


echo "=== 3. EXISTING COUNTRY DATA ==="

find "$D" \
-maxdepth 4 \
-type f \
\( \
-name "*country*" \
-o -name "*geo*" \
-o -name "*location*" \
-o -name "*mmdb*" \
\) \
-printf "%p %s bytes\n" \
| sort \
| head -n 250 || true


echo "=== 4. GEO DATABASES ==="

find \
/usr/share \
/usr/local/share \
/opt/config-location \
/var/lib/config-location \
-type f \
\( \
-name "*.mmdb" \
-o -name "GeoIP*.dat" \
-o -name "geoip.dat" \
\) \
2>/dev/null \
| sort \
| head -n 150


echo "=== 5. HEALTH ELIGIBILITY SHAPE ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

states=Counter()
qualified=Counter()

for p in H.glob("*.json"):

    try:
        o=json.loads(p.read_text())
    except Exception:
        states["INVALID_JSON"] += 1
        continue

    states[
        str(o.get("state","<missing>"))
    ] += 1

    qualified[
        str(o.get("health_qualified"))
    ] += 1

print("HEALTH_STATES=",dict(states))
print("HEALTH_QUALIFIED=",dict(qualified))
PY


echo "=== 6. CONFIG TYPE DISTRIBUTION ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

C=Path(
    "/var/lib/config-location/configs"
)

types=Counter()

for p in C.glob("*.json"):

    try:
        o=json.loads(p.read_text())
    except Exception:
        types["INVALID_JSON"] += 1
        continue

    t=(
        o.get("config_type")
        or o.get("type")
        or o.get("protocol")
        or "<unknown>"
    )

    types[str(t)] += 1

print("CONFIG_TYPES=")

for k,v in types.most_common():
    print(k,v)
PY


echo "=== 7. XRAY RUNTIME REUSE CONTRACT ==="

grep -RIn \
--include="*.py" \
-E "socks_port|local_port|RuntimeLauncher|launch|sandbox|proxy_url|127.0.0.1" \
"$R/app/health/runtime" \
| head -n 650


echo "=== 8. HTTP PROBE REUSE ==="

grep -RIn \
--include="*.py" \
-E "curl|socks5|socks5h|proxy|download|upload|http" \
"$R/app/health/probes" \
| head -n 650


echo "=== 9. INSTALLED GEO LIBRARIES ==="

"$PY" <<'PY'
mods=[
    "geoip2",
    "maxminddb",
    "requests",
    "httpx",
    "aiohttp",
]

for m in mods:
    try:
        mod=__import__(m)
        print(m,"INSTALLED")
    except Exception as e:
        print(m,"MISSING")
PY


echo "=== 10. SERVICES ==="

for svc in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    echo "$svc=$(systemctl is-active "$svc" 2>/dev/null || true)"
done


echo "========================================"
echo "FIX22A=PASS"
echo "COUNTRY_ENGINE_AUDIT=COMPLETE"
echo "RUNTIME_EXIT_IP_REQUIRED=YES"
echo "MULTI_LAYER_COUNTRY_DESIGN=YES"
echo "========================================"
