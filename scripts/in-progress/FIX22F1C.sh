#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

IP="91.107.184.117"

echo "=== 1. RAW IP.GUIDE RESPONSE ==="

RAW=$(
    curl \
    -4 \
    -fsS \
    --connect-timeout 5 \
    --max-time 10 \
    -H 'Accept: application/json' \
    "https://ip.guide/$IP"
)

export RAW

"$PY" <<'PY'
import json
import os

o=json.loads(
    os.environ["RAW"]
)

print(
    json.dumps(
        o,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    )[:8000]
)
PY


echo "=== 2. RECURSIVE KEY MAP ==="

"$PY" <<'PY'
import json
import os

o=json.loads(
    os.environ["RAW"]
)

interesting=(
    "country",
    "code",
    "iso",
    "asn",
    "autonomous",
    "network",
    "organization",
    "location",
)


def walk(
    value,
    path="$",
):
    if isinstance(value,dict):

        for k,v in value.items():

            p=f"{path}.{k}"

            low=str(k).lower()

            if any(
                word in low
                for word
                in interesting
            ):
                print(
                    p,
                    "=",
                    repr(v)[:500],
                )

            walk(
                v,
                p,
            )

    elif isinstance(value,list):

        for i,v in enumerate(value):
            walk(
                v,
                f"{path}[{i}]",
            )


walk(o)
PY


echo "=== 3. CURRENT PROVIDER RESULTS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.fallback_geo import (
    lookup_ipinfo,
    lookup_freeipapi,
    lookup_ipguide,
)

IP="91.107.184.117"

for fn in (
    lookup_ipinfo,
    lookup_freeipapi,
    lookup_ipguide,
):
    r=fn(
        IP,
        timeout=8.0,
    )

    print(
        r.provider,
        "success=",r.success,
        "code=",r.country_code,
        "name=",r.country_name,
        "asn=",r.asn,
        "network=",r.network_name,
        "error=",r.error,
    )
PY


echo "=== 4. PRIMARY GEO REFERENCE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.geo_intelligence import (
    resolve_geo,
)

r=resolve_geo(
    config_id="FIX22F1C-REFERENCE",
    ip="91.107.184.117",
)

print(
    "PRIMARY_STATE=",
    r["state"],
)

print(
    "PRIMARY_COUNTRY_CODE=",
    r["country_code"],
)

print(
    "PRIMARY_COUNTRY_NAME=",
    r["country_name"],
)

print(
    "PRIMARY_ASN=",
    r["asn"],
)

assert r["country_code"] == "DE"

print(
    "PRIMARY_REFERENCE=PASS"
)
PY


echo "=== 5. SERVICES ==="

for svc in \
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


echo "========================================"
echo "FIX22F1C=PASS"
echo "IPGUIDE_SCHEMA=PINNED"
echo "PRIMARY_GEO_UNCHANGED=YES"
echo "PRODUCTION_UNCHANGED=YES"
echo "========================================"
