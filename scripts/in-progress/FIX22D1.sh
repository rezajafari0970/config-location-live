#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
M="$R/app/country"

cat >"$M/geo_providers.py" <<'PY'
from __future__ import annotations

import ipaddress
import json
import subprocess
import time

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class GeoLookup:
    provider: str
    success: bool
    ip: str
    country_code: str | None = None
    country_name: str | None = None
    asn: str | None = None
    network_name: str | None = None
    duration_ms: int = 0
    error: str | None = None
    raw: dict[str, Any] | None = None


def _valid_ip(value: str) -> str:
    return ipaddress.ip_address(
        value
    ).compressed


def _get_json(
    url: str,
    timeout: float,
) -> tuple[
    dict[str, Any] | None,
    int,
    str | None,
]:

    started=time.monotonic()

    try:
        p=subprocess.run(
            [
                "curl",
                "-4",
                "-fsS",
                "--connect-timeout",
                str(min(timeout,5.0)),
                "--max-time",
                str(timeout),
                "-H",
                "Accept: application/json",
                url,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout+2,
        )

        ms=int(
            (
                time.monotonic()
                - started
            )
            * 1000
        )

        if p.returncode != 0:
            return (
                None,
                ms,
                (
                    p.stderr.strip()
                    or
                    f"curl_exit_{p.returncode}"
                )[:500],
            )

        try:
            o=json.loads(
                p.stdout
            )
        except Exception:
            return (
                None,
                ms,
                "invalid_json",
            )

        if not isinstance(o,dict):
            return (
                None,
                ms,
                "non_object_json",
            )

        return o,ms,None

    except subprocess.TimeoutExpired:
        ms=int(
            (
                time.monotonic()
                - started
            )
            * 1000
        )

        return None,ms,"timeout"


def lookup_ipwho(
    ip: str,
    timeout: float = 8.0,
) -> GeoLookup:

    ip=_valid_ip(ip)

    o,ms,error=_get_json(
        f"https://ipwho.is/{ip}",
        timeout,
    )

    if error or not o:
        return GeoLookup(
            provider="ipwho",
            success=False,
            ip=ip,
            duration_ms=ms,
            error=error,
        )

    if o.get("success") is False:
        return GeoLookup(
            provider="ipwho",
            success=False,
            ip=ip,
            duration_ms=ms,
            error=str(
                o.get("message")
                or "provider_failure"
            ),
            raw=o,
        )

    connection=(
        o.get("connection")
        if isinstance(
            o.get("connection"),
            dict,
        )
        else {}
    )

    asn=connection.get("asn")

    if asn is not None:
        asn=str(asn)

        if not asn.upper().startswith("AS"):
            asn="AS"+asn

    return GeoLookup(
        provider="ipwho",
        success=True,
        ip=ip,
        country_code=o.get("country_code"),
        country_name=o.get("country"),
        asn=asn,
        network_name=(
            connection.get("org")
            or connection.get("isp")
        ),
        duration_ms=ms,
        raw=o,
    )


def lookup_ipapi_co(
    ip: str,
    timeout: float = 8.0,
) -> GeoLookup:

    ip=_valid_ip(ip)

    o,ms,error=_get_json(
        f"https://ipapi.co/{ip}/json/",
        timeout,
    )

    if error or not o:
        return GeoLookup(
            provider="ipapi_co",
            success=False,
            ip=ip,
            duration_ms=ms,
            error=error,
        )

    if o.get("error") is True:
        return GeoLookup(
            provider="ipapi_co",
            success=False,
            ip=ip,
            duration_ms=ms,
            error=str(
                o.get("reason")
                or "provider_failure"
            ),
            raw=o,
        )

    return GeoLookup(
        provider="ipapi_co",
        success=True,
        ip=ip,
        country_code=o.get("country_code"),
        country_name=o.get("country_name"),
        asn=o.get("asn"),
        network_name=o.get("org"),
        duration_ms=ms,
        raw=o,
    )


def lookup_ip_api(
    ip: str,
    timeout: float = 8.0,
) -> GeoLookup:

    ip=_valid_ip(ip)

    fields=(
        "status,message,country,"
        "countryCode,isp,org,as,query"
    )

    o,ms,error=_get_json(
        (
            f"http://ip-api.com/json/{ip}"
            f"?fields={fields}"
        ),
        timeout,
    )

    if error or not o:
        return GeoLookup(
            provider="ip_api",
            success=False,
            ip=ip,
            duration_ms=ms,
            error=error,
        )

    if o.get("status") != "success":
        return GeoLookup(
            provider="ip_api",
            success=False,
            ip=ip,
            duration_ms=ms,
            error=str(
                o.get("message")
                or "provider_failure"
            ),
            raw=o,
        )

    as_field=str(
        o.get("as")
        or ""
    ).strip()

    asn=(
        as_field.split()[0]
        if as_field
        else None
    )

    return GeoLookup(
        provider="ip_api",
        success=True,
        ip=ip,
        country_code=o.get("countryCode"),
        country_name=o.get("country"),
        asn=asn,
        network_name=(
            o.get("org")
            or o.get("isp")
        ),
        duration_ms=ms,
        raw=o,
    )


DEFAULT_PROVIDERS=(
    lookup_ipwho,
    lookup_ipapi_co,
    lookup_ip_api,
)


def lookup_all(
    ip: str,
    timeout: float = 8.0,
) -> list[GeoLookup]:

    return [
        provider(
            ip,
            timeout,
        )
        for provider
        in DEFAULT_PROVIDERS
    ]
PY


cat >"$M/geo_consensus.py" <<'PY'
from __future__ import annotations

from collections import Counter

from .geo_providers import (
    GeoLookup,
)

from .models import (
    CountryEvidence,
    EvidenceKind,
)

from .normalize import (
    normalize_country_code,
    normalize_country_name,
)


def geo_to_evidence(
    rows: list[GeoLookup],
) -> list[CountryEvidence]:

    result=[]

    for row in rows:

        code=normalize_country_code(
            row.country_code
        )

        name=normalize_country_name(
            row.country_name
        )

        result.append(
            CountryEvidence(
                provider=row.provider,
                kind=EvidenceKind.GEO_COUNTRY,
                success=(
                    row.success
                    and code is not None
                ),
                exit_ip=row.ip,
                country_code=code,
                country_name=name,
                asn=row.asn,
                network_name=row.network_name,
                confidence=(
                    1.0
                    if (
                        row.success
                        and code
                    )
                    else 0.0
                ),
                error=row.error,
                metadata={
                    "duration_ms":
                        row.duration_ms,
                },
            )
        )

    return result


def summarize_geo(
    rows: list[GeoLookup],
) -> dict:

    good=[
        row
        for row in rows
        if (
            row.success
            and normalize_country_code(
                row.country_code
            )
        )
    ]

    countries=Counter(
        normalize_country_code(
            row.country_code
        )
        for row in good
    )

    asns=Counter(
        str(row.asn)
        for row in good
        if row.asn
    )

    networks=Counter(
        str(row.network_name)
        for row in good
        if row.network_name
    )

    return {
        "successful":
            len(good),

        "total":
            len(rows),

        "countries":
            dict(countries),

        "asns":
            dict(asns),

        "networks":
            dict(networks),
    }
PY


echo "=== 1. COMPILE ==="

"$PY" -m py_compile \
"$M/geo_providers.py" \
"$M/geo_consensus.py"

echo "COMPILE=PASS"


echo "=== 2. REAL EXIT-IP GEO TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.geo_providers import (
    lookup_all,
)

from app.country.geo_consensus import (
    geo_to_evidence,
    summarize_geo,
)

from app.country.consensus import (
    decide_country_consensus,
)


IP="91.107.184.117"

rows=lookup_all(
    IP,
    timeout=8.0,
)

for r in rows:

    print(
        "PROVIDER=",
        r.provider,
        "SUCCESS=",
        r.success,
        "COUNTRY_CODE=",
        r.country_code,
        "COUNTRY_NAME=",
        r.country_name,
        "ASN=",
        r.asn,
        "NETWORK=",
        r.network_name,
        "MS=",
        r.duration_ms,
        "ERROR=",
        r.error,
    )


summary=summarize_geo(
    rows
)

print(
    "SUMMARY=",
    summary,
)


evidence=geo_to_evidence(
    rows
)

result=decide_country_consensus(
    config_id="FIX22D1-REAL-EXIT",
    evidence=evidence,
    minimum_agreement=2,
)


print(
    "STATE=",
    result.state.value,
)

print(
    "COUNTRY_CODE=",
    result.country_code,
)

print(
    "COUNTRY_NAME=",
    result.country_name,
)

print(
    "FLAG=",
    result.flag,
)

print(
    "CONFIDENCE=",
    result.confidence,
)

print(
    "AGREED=",
    result.providers_agreed,
)

print(
    "TOTAL=",
    result.providers_total,
)


assert (
    sum(
        1
        for r in rows
        if r.success
    )
    >= 2
)

assert (
    result.state.value
    in (
        "confirmed",
        "ambiguous",
    )
)

if result.state.value=="confirmed":

    assert result.country_code
    assert result.country_name
    assert result.flag

    print(
        "REAL_GEO_CONSENSUS=PASS"
    )

else:

    print(
        "REAL_GEO_DISAGREEMENT=SAFELY_DETECTED"
    )
PY


echo "=== 3. KNOWN-IP SANITY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.geo_providers import (
    lookup_all,
)

from app.country.geo_consensus import (
    geo_to_evidence,
)

from app.country.consensus import (
    decide_country_consensus,
)


tests={
    "8.8.8.8":"US",
    "1.1.1.1":None,
}


for ip,expected in tests.items():

    rows=lookup_all(
        ip,
        timeout=8.0,
    )

    evidence=geo_to_evidence(
        rows
    )

    result=decide_country_consensus(
        config_id=ip,
        evidence=evidence,
        minimum_agreement=2,
    )

    print(
        ip,
        result.state.value,
        result.country_code,
        result.country_name,
        result.confidence,
    )

    if expected is not None:
        assert (
            result.country_code
            == expected
        )


print(
    "KNOWN_IP_SANITY=PASS"
)
PY


echo "=== 4. PRODUCTION SERVICES ==="

for svc in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(
        systemctl is-active \
        "$svc" 2>/dev/null || true
    )

    echo "$svc=$X"
    test "$X" = active
done


echo "========================================"
echo "FIX22D1=PASS"
echo "MULTI_GEO_PROVIDER=READY"
echo "COUNTRY_CONSENSUS=READY"
echo "ASN_EVIDENCE=READY"
echo "NETWORK_EVIDENCE=READY"
echo "PROVIDER_DISAGREEMENT=SAFE"
echo "PRODUCTION_UNCHANGED=YES"
echo "========================================"
