#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
GP="$R/app/country/geo_providers.py"

echo "=== 1. DEFAULT PROVIDERS ==="

grep -n \
-B15 -A35 \
'DEFAULT_PROVIDERS' \
"$GP"


echo
echo "=== 2. GEOLOOKUP CONTRACT ==="

grep -n \
-B10 -A55 \
'class GeoLookup' \
"$GP"


echo
echo "=== 3. PROVIDER FUNCTIONS ==="

"$PY" <<'PY'
from pathlib import Path
import ast

p=Path(
    "/opt/config-location/app/country/"
    "geo_providers.py"
)

s=p.read_text()
t=ast.parse(s)

for n in t.body:

    if not isinstance(
        n,
        ast.FunctionDef,
    ):
        continue

    if n.name.startswith(
        "lookup_"
    ):

        print(
            f"{n.name}:"
            f"{n.lineno}-"
            f"{n.end_lineno}"
        )
PY


echo
echo "=== 4. LOOKUP_ALL CURRENT ==="

nl -ba "$GP" \
| sed -n '295,330p'


echo
echo "=== 5. PROVIDER COUNT RUNTIME ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.geo_providers import (
    DEFAULT_PROVIDERS,
)

print(
    "PROVIDER_COUNT=",
    len(DEFAULT_PROVIDERS),
)

for p in DEFAULT_PROVIDERS:

    print(
        "PROVIDER=",
        p.__name__,
    )
PY


echo
echo "=== 6. CACHE BYPASS BENCHMARK CANDIDATES ==="

"$PY" <<'PY'
from pathlib import Path
import json

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

seen=set()
ips=[]

for p in H.glob("*.json"):

    try:
        h=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    fast=(
        (
            h.get("metadata")
            or {}
        ).get(
            "same_runtime_country"
        )
    )

    if not isinstance(
        fast,
        dict,
    ):
        continue

    ip=fast.get("exit_ip")

    if not ip:
        continue

    ip=str(ip)

    if ip in seen:
        continue

    seen.add(ip)
    ips.append(ip)

    if len(ips)>=20:
        break


print(
    "BENCHMARK_IPS=",
    len(ips),
)

for ip in ips:
    print(ip)
PY


echo
echo "=== 7. QUEUE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print("QUEUE=",stats())
PY


echo
echo "=== 8. SERVICES ==="

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
echo "FIX22K5A=PASS"
echo "MODE=PARALLEL-GEO-CONTRACT-PIN"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=FIX22K5B"
echo "========================================"
