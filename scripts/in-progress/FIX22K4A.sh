#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

echo "=== 1. GEO MODULE INVENTORY ==="

find "$R/app/country" \
    -maxdepth 1 \
    -type f \
    -name '*.py' \
    -printf '%f\n' \
| sort \
| grep -E \
'geo|provider|lookup|consensus|rdap|asn|cache' \
|| true


echo
echo "=== 2. GEO PROVIDER IMPLEMENTATIONS ==="

grep -RIn \
--include='*.py' \
-B25 -A120 \
-E \
'def .*geo|def .*lookup|GeoResult|GeoEvidence|country_code|provider.*ip|ipapi|ipinfo|ipwho|country.is|rdap' \
"$R/app/country" \
| head -n 2600 || true


echo
echo "=== 3. GEO CONSENSUS CONTRACT ==="

nl -ba \
"$R/app/country/geo_consensus.py" \
2>/dev/null \
| sed -n '1,420p' || true


echo
echo "=== 4. PIPELINE GEO WINDOW ==="

grep -n \
-B90 -A220 \
-E \
'geo|consensus|provider|country_code|exit_ip' \
"$R/app/country/pipeline.py" \
| head -n 1200


echo
echo "=== 5. EXISTING CACHE SEARCH ==="

grep -RIn \
--include='*.py' \
-E \
'cache|CACHE|ttl|expires|single.flight|lock|flock|memo' \
"$R/app/country" \
| head -n 1200 || true


echo
echo "=== 6. GEO CALLER MAP ==="

"$PY" <<'PY'
from pathlib import Path
import ast

root=Path(
    "/opt/config-location/app/country"
)

for p in root.glob("*.py"):

    try:
        s=p.read_text()
        t=ast.parse(s)
    except Exception:
        continue

    for n in ast.walk(t):

        if not isinstance(
            n,
            ast.Call,
        ):
            continue

        name=""

        if isinstance(
            n.func,
            ast.Name,
        ):
            name=n.func.id

        elif isinstance(
            n.func,
            ast.Attribute,
        ):
            name=n.func.attr

        low=name.lower()

        if (
            "geo" in low
            or "lookup" in low
        ):
            print(
                f"{p.name}:"
                f"{n.lineno}:"
                f"{name}"
            )
PY


echo
echo "=== 7. EXIT-IP REUSE ANALYSIS ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

ips=Counter()

handoffs=0

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

    ip=fast.get(
        "exit_ip"
    )

    if not ip:
        continue

    handoffs+=1
    ips[str(ip)]+=1


print(
    "HANDOFF_WITH_IP=",
    handoffs,
)

print(
    "UNIQUE_EXIT_IPS=",
    len(ips),
)

duplicates=sum(
    n-1
    for n in ips.values()
    if n>1
)

print(
    "DUPLICATE_LOOKUPS_AVOIDABLE=",
    duplicates,
)

print(
    "TOP_REUSED_IPS="
)

for ip,n in ips.most_common(20):
    print(ip,n)
PY


echo
echo "=== 8. CURRENT QUEUE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "QUEUE=",
    stats(),
)
PY


echo
echo "=== 9. SERVICES ==="

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
echo "FIX22K4A=PASS"
echo "MODE=GEO-CACHE-SINGLEFLIGHT-CONTRACT"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=FIX22K4B"
echo "========================================"
