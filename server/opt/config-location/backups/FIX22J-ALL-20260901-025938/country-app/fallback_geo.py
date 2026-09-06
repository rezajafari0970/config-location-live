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
