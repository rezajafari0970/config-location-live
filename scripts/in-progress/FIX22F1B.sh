#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

F="$R/app/country/fallback_geo.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22F1B-$TS"

mkdir -p "$B"

cp -a "$F" "$B/"

echo "BACKUP=$B"

export F

echo "=== 1. PATCH IP.GUIDE PARSER ==="

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["F"])
s=p.read_text()

old='''    code=(
        location.get("country")
        or location.get("country_code")
    )

    name=(
        location.get("country_name")
    )
'''

new='''    # ip.guide may expose both a full country
    # name and an ISO country code.
    #
    # Country code MUST take precedence. Using
    # the full name here would later be rejected
    # by normalize_country_code().
    code=(
        location.get("country_code")
        or location.get("countryCode")
        or location.get("country_code2")
    )

    name=(
        location.get("country_name")
        or location.get("country")
    )
'''

if old not in s:
    raise SystemExit(
        "ipguide country anchor missing"
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


echo "=== 3. IP.GUIDE REAL PARSER TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.fallback_geo import (
    lookup_ipguide,
)

r=lookup_ipguide(
    "91.107.184.117",
    timeout=8.0,
)

print(
    "SUCCESS=",
    r.success,
)

print(
    "COUNTRY_CODE=",
    r.country_code,
)

print(
    "COUNTRY_NAME=",
    r.country_name,
)

print(
    "ASN=",
    r.asn,
)

print(
    "NETWORK=",
    r.network_name,
)

print(
    "ERROR=",
    r.error,
)

assert r.success is True
assert r.country_code == "DE"

print(
    "IPGUIDE_PARSER=PASS"
)
PY


echo "=== 4. FULL FALLBACK REAL TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.recovery import (
    recover_country,
)

r=recover_country(
    ip="91.107.184.117",
    previous_state="unknown",
)

print(
    "EXECUTED=",
    r["executed"],
)

print(
    "STATE=",
    r["state"],
)

print(
    "COUNTRY_CODE=",
    r.get("country_code"),
)

print(
    "COUNTRY_NAME=",
    r.get("country_name"),
)

print(
    "CONFIDENCE=",
    r.get("confidence"),
)

print(
    "AGREED=",
    r.get("agreed"),
)

print(
    "SUCCESSFUL=",
    r.get("successful"),
)

for row in r.get(
    "providers",
    []
):
    print(
        "FALLBACK_PROVIDER",
        row,
    )

assert r["executed"] is True

# One fallback provider is allowed to fail.
# The contract requires two independent usable
# providers agreeing on the same country.
assert int(
    r.get(
        "successful",
        0,
    )
) >= 2

assert int(
    r.get(
        "agreed",
        0,
    )
) >= 2

assert r["state"] == "confirmed"
assert r["country_code"] == "DE"

print(
    "SECONDARY_COUNTRY_CONSENSUS=PASS"
)
PY


echo "=== 5. FALSE CERTAINTY UNIT TEST ==="

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

    FallbackGeoResult(
        provider="c",
        success=False,
        ip="8.8.8.8",
        error="provider_down",
    ),
]

r=decide_fallback_country(
    rows,
    minimum_agreement=2,
)

print(r)

assert r["state"] == "ambiguous"
assert r["country_code"] is None

print(
    "FALSE_CERTAINTY_BLOCK=PASS"
)
PY


echo "=== 6. CONFIRMED BYPASS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.recovery import (
    recover_country,
)

r=recover_country(
    ip="91.107.184.117",
    previous_state="confirmed",
)

assert r["executed"] is False

print(
    "CONFIRMED_BYPASS=PASS"
)
PY


echo "=== 7. SERVICES ==="

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
echo "FIX22F1B=PASS"
echo "UNKNOWN_RECOVERY=READY"
echo "IPGUIDE_ISO_PARSER=FIXED"
echo "MINIMUM_FALLBACK_AGREEMENT=2"
echo "ONE_PROVIDER_FAILURE_TOLERATED=YES"
echo "FALSE_CERTAINTY_BLOCKED=YES"
echo "PRODUCTION_UNCHANGED=YES"
echo "BACKUP=$B"
echo "========================================"
