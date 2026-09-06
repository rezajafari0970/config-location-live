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
