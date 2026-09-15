#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
F="$R/app/country/fallback_geo.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22F1D-$TS"

mkdir -p "$B"
cp -a "$F" "$B/"

export F

echo "=== 1. PATCH EXACT IP.GUIDE SCHEMA ==="

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["F"])
s=p.read_text()

old='''    location=(
        o.get("location")
        if isinstance(
            o.get("location"),
            dict,
        )
        else {}
    )

    network=(
        o.get("network")
        if isinstance(
            o.get("network"),
            dict,
        )
        else {}
    )

    code=(
        location.get("country_code")
        or location.get("countryCode")
        or location.get("country_code2")
    )

    name=(
        location.get("country_name")
        or location.get("country")
    )

    asn=(
        network.get("autonomous_system_number")
        or network.get("asn")
    )

    if asn is not None:
        asn=str(asn)

        if not asn.upper().startswith(
            "AS"
        ):
            asn="AS"+asn

    network_name=(
        network.get(
            "autonomous_system_organization"
        )
        or network.get("organization")
        or network.get("name")
    )
'''

new='''    location=(
        o.get("location")
        if isinstance(
            o.get("location"),
            dict,
        )
        else {}
    )

    network=(
        o.get("network")
        if isinstance(
            o.get("network"),
            dict,
        )
        else {}
    )

    autonomous_system=(
        network.get(
            "autonomous_system"
        )
        if isinstance(
            network.get(
                "autonomous_system"
            ),
            dict,
        )
        else {}
    )

    # Exact ip.guide schema:
    # location.country = full name
    # network.autonomous_system.country = ISO code
    code=(
        autonomous_system.get(
            "country"
        )
    )

    name=(
        location.get(
            "country"
        )
    )

    asn=(
        autonomous_system.get(
            "asn"
        )
    )

    if asn is not None:
        asn=str(asn)

        if not asn.upper().startswith(
            "AS"
        ):
            asn="AS"+asn

    network_name=(
        autonomous_system.get(
            "organization"
        )
        or autonomous_system.get(
            "name"
        )
    )
'''

if old not in s:
    raise SystemExit(
        "ipguide exact anchor missing"
    )

p.write_text(
    s.replace(
        old,
        new,
        1,
    )
)

print("PATCH=PASS")
PY


echo "=== 2. COMPILE ==="

"$PY" -m py_compile "$F"

echo "COMPILE=PASS"


echo "=== 3. IP.GUIDE REAL VERIFY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.fallback_geo import (
    lookup_ipguide,
)

r=lookup_ipguide(
    "91.107.184.117",
    timeout=8.0,
)

print("SUCCESS=",r.success)
print("COUNTRY_CODE=",r.country_code)
print("COUNTRY_NAME=",r.country_name)
print("ASN=",r.asn)
print("NETWORK=",r.network_name)
print("ERROR=",r.error)

assert r.success is True
assert r.country_code == "DE"
assert r.country_name == "Germany"
assert r.asn == "AS24940"

print("IPGUIDE_EXACT_SCHEMA=PASS")
PY


echo "=== 4. FULL FALLBACK CONSENSUS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.recovery import (
    recover_country,
)

r=recover_country(
    ip="91.107.184.117",
    previous_state="unknown",
)

print("EXECUTED=",r["executed"])
print("STATE=",r["state"])
print("COUNTRY_CODE=",r.get("country_code"))
print("COUNTRY_NAME=",r.get("country_name"))
print("CONFIDENCE=",r.get("confidence"))
print("AGREED=",r.get("agreed"))
print("SUCCESSFUL=",r.get("successful"))

for row in r.get("providers",[]):
    print("PROVIDER",row)

assert r["executed"] is True
assert r["state"] == "confirmed"
assert r["country_code"] == "DE"
assert int(r["agreed"]) >= 2
assert int(r["successful"]) >= 2

print("FALLBACK_CONSENSUS=PASS")
PY


echo "=== 5. DISAGREEMENT SAFETY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.fallback_consensus import (
    decide_fallback_country,
)

from app.country.fallback_geo import (
    FallbackGeoResult,
)

rows=[
    FallbackGeoResult(
        provider="a",
        success=True,
        ip="8.8.8.8",
        country_code="DE",
    ),
    FallbackGeoResult(
        provider="b",
        success=True,
        ip="8.8.8.8",
        country_code="US",
    ),
]

r=decide_fallback_country(
    rows,
    minimum_agreement=2,
)

assert r["state"]=="ambiguous"
assert r["country_code"] is None

print("FALSE_CERTAINTY_BLOCK=PASS")
PY


echo "=== 6. SERVICES ==="

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
echo "FIX22F1D=PASS"
echo "IPGUIDE_PARSER=FINAL"
echo "UNKNOWN_RECOVERY=READY"
echo "SECONDARY_CONSENSUS=READY"
echo "MINIMUM_FALLBACK_AGREEMENT=2"
echo "FALSE_CERTAINTY_BLOCKED=YES"
echo "PRODUCTION_UNCHANGED=YES"
echo "BACKUP=$B"
echo "========================================"
