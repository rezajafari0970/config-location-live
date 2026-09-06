#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
F="$R/app/country/fallback_geo.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22F1E-$TS"

mkdir -p "$B"
cp -a "$F" "$B/"

export F

echo "=== 1. REPLACE lookup_ipguide FUNCTION ==="

"$PY" <<'PY'
from pathlib import Path
import os
import ast

p=Path(os.environ["F"])
s=p.read_text()

tree=ast.parse(s)

target=None

for node in tree.body:
    if (
        isinstance(
            node,
            ast.FunctionDef,
        )
        and
        node.name=="lookup_ipguide"
    ):
        target=node
        break

if target is None:
    raise SystemExit(
        "lookup_ipguide function missing"
    )

lines=s.splitlines(
    keepends=True
)

start=target.lineno-1

end=(
    target.end_lineno
)

new='''def lookup_ipguide(
    ip: str,
    timeout: float = 8.0,
) -> FallbackGeoResult:

    ip=_ip(ip)

    o,ms,error=_json_get(
        f"https://ip.guide/{ip}",
        timeout,
    )

    if error or not o:
        return FallbackGeoResult(
            provider="ipguide",
            success=False,
            ip=ip,
            duration_ms=ms,
            error=error,
        )

    location=(
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

    # Exact schema verified in FIX22F1C:
    #
    # location.country
    #   -> full country name
    #
    # network.autonomous_system.country
    #   -> ISO-3166 alpha-2 country code
    #
    # network.autonomous_system.asn
    #   -> ASN integer
    #
    # network.autonomous_system.organization
    #   -> network organization

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

        asn=str(asn).strip()

        if asn:

            if not asn.upper().startswith(
                "AS"
            ):
                asn="AS"+asn

        else:
            asn=None

    network_name=(
        autonomous_system.get(
            "organization"
        )
        or
        autonomous_system.get(
            "name"
        )
    )

    if not code:
        return FallbackGeoResult(
            provider="ipguide",
            success=False,
            ip=ip,
            duration_ms=ms,
            error="missing_country_code",
        )

    return FallbackGeoResult(
        provider="ipguide",
        success=True,
        ip=ip,
        country_code=str(
            code
        ),
        country_name=(
            str(name)
            if name
            else None
        ),
        asn=asn,
        network_name=(
            str(network_name)
            if network_name
            else None
        ),
        duration_ms=ms,
    )
'''

lines[
    start:end
]=[
    new+"\n"
]

p.write_text(
    "".join(lines)
)

print(
    "FUNCTION_REPLACEMENT=PASS"
)
PY


echo "=== 2. COMPILE ==="

"$PY" -m py_compile "$F"

echo "COMPILE=PASS"


echo "=== 3. EXACT PROVIDER VERIFY ==="

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
assert r.country_code=="DE"
assert r.country_name=="Germany"
assert r.asn=="AS24940"

print(
    "IPGUIDE_PROVIDER=PASS"
)
PY


echo "=== 4. SECONDARY CONSENSUS ==="

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
    "AGREED=",
    r.get("agreed"),
)

print(
    "SUCCESSFUL=",
    r.get("successful"),
)

print(
    "CONFIDENCE=",
    r.get("confidence"),
)

for row in r.get(
    "providers",
    []
):
    print(
        "PROVIDER",
        row,
    )

assert r["executed"] is True
assert r["state"]=="confirmed"
assert r["country_code"]=="DE"

assert int(
    r["agreed"]
) >= 2

assert int(
    r["successful"]
) >= 2

print(
    "SECONDARY_CONSENSUS=PASS"
)
PY


echo "=== 5. CONFIRMED BYPASS ==="

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


echo "=== 6. FALSE CERTAINTY TEST ==="

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
        error="offline",
    ),
]

r=decide_fallback_country(
    rows,
    minimum_agreement=2,
)

print(r)

assert r["state"]=="ambiguous"
assert r["country_code"] is None

print(
    "FALSE_CERTAINTY_BLOCK=PASS"
)
PY


echo "=== 7. PRODUCTION SERVICES ==="

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
echo "FIX22F1E=PASS"
echo "IPGUIDE_PARSER=FINAL"
echo "UNKNOWN_RECOVERY=READY"
echo "SECONDARY_COUNTRY_CONSENSUS=PASS"
echo "FALSE_CERTAINTY_BLOCKED=YES"
echo "PRODUCTION_UNCHANGED=YES"
echo "BACKUP=$B"
echo "========================================"
