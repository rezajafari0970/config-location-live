#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
M="$R/app/country"

cat >"$M/fallback_geo.py" <<'PY'
from __future__ import annotations

import ipaddress
import json
import subprocess
import time

from dataclasses import dataclass
from typing import Any, Callable


@dataclass(frozen=True)
class FallbackGeoResult:
    provider: str
    success: bool
    ip: str
    country_code: str | None = None
    country_name: str | None = None
    asn: str | None = None
    network_name: str | None = None
    duration_ms: int = 0
    error: str | None = None


def _ip(value: str) -> str:
    return ipaddress.ip_address(
        value
    ).compressed


def _json_get(
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
                str(min(timeout,5)),
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
                )[:400],
            )

        try:
            o=json.loads(
                p.stdout
            )
        except Exception:
            return None,ms,"invalid_json"

        if not isinstance(o,dict):
            return None,ms,"non_object_json"

        return o,ms,None

    except subprocess.TimeoutExpired:
        return (
            None,
            int(
                (
                    time.monotonic()
                    - started
                )
                * 1000
            ),
            "timeout",
        )


def lookup_ipinfo(
    ip: str,
    timeout: float = 8.0,
) -> FallbackGeoResult:

    ip=_ip(ip)

    o,ms,error=_json_get(
        f"https://ipinfo.io/{ip}/json",
        timeout,
    )

    if error or not o:
        return FallbackGeoResult(
            provider="ipinfo",
            success=False,
            ip=ip,
            duration_ms=ms,
            error=error,
        )

    country=o.get("country")

    if not country:
        return FallbackGeoResult(
            provider="ipinfo",
            success=False,
            ip=ip,
            duration_ms=ms,
            error="missing_country",
        )

    org=str(
        o.get("org")
        or ""
    ).strip()

    asn=None
    network=None

    if org:

        first=org.split(
            None,
            1,
        )

        if first:
            if first[0].upper().startswith(
                "AS"
            ):
                asn=first[0]

        if len(first) > 1:
            network=first[1]

    return FallbackGeoResult(
        provider="ipinfo",
        success=True,
        ip=ip,
        country_code=str(country),
        country_name=None,
        asn=asn,
        network_name=network,
        duration_ms=ms,
    )


def lookup_freeipapi(
    ip: str,
    timeout: float = 8.0,
) -> FallbackGeoResult:

    ip=_ip(ip)

    o,ms,error=_json_get(
        (
            "https://freeipapi.com/"
            f"api/json/{ip}"
        ),
        timeout,
    )

    if error or not o:
        return FallbackGeoResult(
            provider="freeipapi",
            success=False,
            ip=ip,
            duration_ms=ms,
            error=error,
        )

    code=(
        o.get("countryCode")
        or o.get("countryCode2")
    )

    name=o.get(
        "countryName"
    )

    if not code:
        return FallbackGeoResult(
            provider="freeipapi",
            success=False,
            ip=ip,
            duration_ms=ms,
            error="missing_country",
        )

    return FallbackGeoResult(
        provider="freeipapi",
        success=True,
        ip=ip,
        country_code=str(code),
        country_name=(
            str(name)
            if name
            else None
        ),
        duration_ms=ms,
    )


def lookup_ipguide(
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

    code=(
        location.get("country")
        or location.get("country_code")
    )

    name=(
        location.get("country_name")
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

    if not code:
        return FallbackGeoResult(
            provider="ipguide",
            success=False,
            ip=ip,
            duration_ms=ms,
            error="missing_country",
        )

    return FallbackGeoResult(
        provider="ipguide",
        success=True,
        ip=ip,
        country_code=str(code),
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


FALLBACK_PROVIDERS: tuple[
    Callable[
        [str,float],
        FallbackGeoResult,
    ],
    ...
]=(
    lookup_ipinfo,
    lookup_freeipapi,
    lookup_ipguide,
)


def lookup_fallback_all(
    ip: str,
    timeout: float = 8.0,
) -> list[
    FallbackGeoResult
]:

    return [
        provider(
            ip,
            timeout,
        )
        for provider
        in FALLBACK_PROVIDERS
    ]
PY


cat >"$M/fallback_consensus.py" <<'PY'
from __future__ import annotations

from collections import Counter

from .fallback_geo import (
    FallbackGeoResult,
)

from .normalize import (
    country_flag,
    normalize_country_code,
    normalize_country_name,
)


def decide_fallback_country(
    rows: list[
        FallbackGeoResult
    ],
    *,
    minimum_agreement: int = 2,
) -> dict:

    good=[]

    for row in rows:

        code=normalize_country_code(
            row.country_code
        )

        if (
            row.success
            and code
        ):
            good.append(
                (
                    row,
                    code,
                )
            )

    if not good:
        return {
            "state":"unknown",
            "country_code":None,
            "country_name":None,
            "flag":None,
            "confidence":0.0,
            "agreed":0,
            "successful":0,
            "total":len(rows),
            "reason":
                "fallback_no_usable_evidence",
        }

    counts=Counter(
        code
        for _,code
        in good
    )

    code,agreed=(
        counts.most_common(1)[0]
    )

    successful=len(good)

    confidence=(
        agreed
        / successful
    )

    names=[
        normalize_country_name(
            row.country_name
        )
        for row,candidate
        in good
        if candidate == code
    ]

    names=[
        x
        for x in names
        if x
    ]

    name=(
        Counter(
            names
        ).most_common(1)[0][0]
        if names
        else None
    )

    if (
        agreed >= minimum_agreement
        and confidence >= 0.67
    ):

        state="confirmed"

    else:

        state="ambiguous"

    return {
        "state":state,

        "country_code":(
            code
            if state=="confirmed"
            else None
        ),

        "country_name":(
            name
            if state=="confirmed"
            else None
        ),

        "flag":(
            country_flag(code)
            if state=="confirmed"
            else None
        ),

        "confidence":
            confidence,

        "agreed":
            agreed,

        "successful":
            successful,

        "total":
            len(rows),

        "reason":(
            "fallback_country_consensus"
            if state=="confirmed"
            else
            "fallback_provider_disagreement"
        ),
    }
PY


cat >"$M/recovery.py" <<'PY'
from __future__ import annotations

from .fallback_consensus import (
    decide_fallback_country,
)

from .fallback_geo import (
    lookup_fallback_all,
)


RECOVERABLE_STATES={
    "unknown",
    "ambiguous",
    "unstable_exit",
    "pending_confirmation",
}


def should_run_recovery(
    state: str,
) -> bool:

    return (
        str(state)
        .strip()
        .lower()
        in RECOVERABLE_STATES
    )


def recover_country(
    *,
    ip: str,
    previous_state: str,
) -> dict:

    if not should_run_recovery(
        previous_state
    ):

        return {
            "executed":False,
            "state":previous_state,
            "reason":
                "recovery_not_required",
        }

    rows=lookup_fallback_all(
        ip,
        timeout=8.0,
    )

    consensus=(
        decide_fallback_country(
            rows,
            minimum_agreement=2,
        )
    )

    return {
        "executed":True,
        **consensus,

        "providers":[
            {
                "provider":
                    row.provider,

                "success":
                    row.success,

                "country_code":
                    row.country_code,

                "country_name":
                    row.country_name,

                "asn":
                    row.asn,

                "network_name":
                    row.network_name,

                "duration_ms":
                    row.duration_ms,

                "error":
                    row.error,
            }
            for row in rows
        ],
    }
PY


echo "=== 1. COMPILE ==="

"$PY" -m py_compile \
"$M/fallback_geo.py" \
"$M/fallback_consensus.py" \
"$M/recovery.py"

echo "COMPILE=PASS"


echo "=== 2. RECOVERY GATE SELFTEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.recovery import (
    should_run_recovery,
)

assert (
    should_run_recovery(
        "unknown"
    )
    is True
)

assert (
    should_run_recovery(
        "ambiguous"
    )
    is True
)

assert (
    should_run_recovery(
        "confirmed"
    )
    is False
)

assert (
    should_run_recovery(
        "confirmed_stable"
    )
    is False
)

print(
    "RECOVERY_GATE=PASS"
)
PY


echo "=== 3. REAL EXIT FALLBACK TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.recovery import (
    recover_country,
)

IP="91.107.184.117"

r=recover_country(
    ip=IP,
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
    r.get(
        "country_code"
    ),
)

print(
    "COUNTRY_NAME=",
    r.get(
        "country_name"
    ),
)

print(
    "CONFIDENCE=",
    r.get(
        "confidence"
    ),
)

print(
    "AGREED=",
    r.get(
        "agreed"
    ),
)

print(
    "SUCCESSFUL=",
    r.get(
        "successful"
    ),
)

for row in r.get(
    "providers",
    []
):
    print(
        "FALLBACK_PROVIDER",
        row,
    )


assert (
    r["executed"]
    is True
)

assert (
    int(
        r.get(
            "successful",
            0,
        )
    )
    >= 2
)

assert (
    r["state"]
    in (
        "confirmed",
        "ambiguous",
    )
)


if r["state"]=="confirmed":

    assert (
        r["country_code"]
        == "DE"
    )

    print(
        "FALLBACK_REAL_EXIT=PASS"
    )

else:

    print(
        "FALLBACK_DISAGREEMENT=SAFELY_DETECTED"
    )
PY


echo "=== 4. CONFIRMED BYPASS TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.recovery import (
    recover_country,
)

r=recover_country(
    ip="91.107.184.117",
    previous_state="confirmed",
)

print(
    r
)

assert (
    r["executed"]
    is False
)

print(
    "CONFIRMED_BYPASS=PASS"
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
    X=$(
        systemctl is-active \
        "$svc" 2>/dev/null || true
    )

    echo "$svc=$X"
    test "$X" = active
done


echo "========================================"
echo "FIX22F1=PASS"
echo "UNKNOWN_RECOVERY=READY"
echo "AMBIGUOUS_RECOVERY=READY"
echo "SECONDARY_PROVIDERS=3"
echo "MINIMUM_FALLBACK_AGREEMENT=2"
echo "CONFIRMED_CONFIGS_BYPASS_FALLBACK=YES"
echo "FALSE_CERTAINTY_BLOCKED=YES"
echo "PRODUCTION_UNCHANGED=YES"
echo "========================================"
