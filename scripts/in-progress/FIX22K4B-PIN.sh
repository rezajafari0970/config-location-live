#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

GI="$R/app/country/geo_intelligence.py"
GC="$R/app/country/geo_cache.py"
GP="$R/app/country/geo_providers.py"

echo "=== 1. COMPLETE RESOLVE_GEO ==="

"$PY" <<'PY'
from pathlib import Path
import ast

p=Path(
    "/opt/config-location/app/country/"
    "geo_intelligence.py"
)

s=p.read_text()
t=ast.parse(s)

for n in t.body:

    if (
        isinstance(n,ast.FunctionDef)
        and n.name=="resolve_geo"
    ):

        print(
            "RESOLVE_GEO_LINES=",
            n.lineno,
            n.end_lineno,
        )

        lines=s.splitlines()

        for i in range(
            n.lineno-1,
            n.end_lineno,
        ):
            print(
                f"{i+1:04d}: "
                +lines[i]
            )

        break
PY


echo
echo "=== 2. COMPLETE GEO CACHE ==="

nl -ba "$GC" \
| sed -n '1,240p'


echo
echo "=== 3. LOOKUP_ALL ==="

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

    if (
        isinstance(n,ast.FunctionDef)
        and n.name=="lookup_all"
    ):

        print(
            "LOOKUP_ALL_LINES=",
            n.lineno,
            n.end_lineno,
        )

        lines=s.splitlines()

        for i in range(
            n.lineno-1,
            n.end_lineno,
        ):
            print(
                f"{i+1:04d}: "
                +lines[i]
            )

        break
PY


echo
echo "=== 4. CACHE CURRENT FILE COUNT ==="

CACHE=/var/lib/config-location/country/geo-cache

if [ -d "$CACHE" ]; then

    N=$(
        find "$CACHE" \
        -maxdepth 1 \
        -type f \
        | wc -l
    )

else
    N=0
fi

echo "CACHE_FILES=$N"


echo
echo "=== 5. CURRENT CACHE HIT COVERAGE ==="

"$PY" <<'PY'
from pathlib import Path
import json

P=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

total=0
hits=0

for p in P.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    primary=(
        o.get("primary")
        or
        (
            o.get("metadata")
            or {}
        ).get("primary")
        or {}
    )

    if not isinstance(primary,dict):
        continue

    if "cache_hit" not in primary:
        continue

    total+=1

    if primary.get(
        "cache_hit"
    ) is True:
        hits+=1


print(
    "GEO_RESULTS_WITH_CACHE_FIELD=",
    total,
)

print(
    "CACHE_HITS=",
    hits,
)
PY


echo
echo "=== 6. QUEUE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print("QUEUE=",stats())
PY


echo
echo "=== 7. SERVICES ==="

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
echo "FIX22K4B_PIN=PASS"
echo "PRODUCTION_CHANGED=NO"
echo "EXISTING_CACHE=REUSE"
echo "NEXT=FIX22K4B-SINGLEFLIGHT"
echo "========================================"
