from __future__ import annotations

import ipaddress
import json
import subprocess
import time

from collections import Counter
from concurrent.futures import (
    ThreadPoolExecutor,
    as_completed,
    TimeoutError as FuturesTimeoutError,
)

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
    minimum_agreement: int = 2,
    evidence_grace_seconds: float = 0.35,
) -> list[GeoLookup]:
    """
    FIX22K5_PARALLEL_GEO

    All independent Geo providers start concurrently.

    Once country consensus is reached, allow a short
    evidence grace window for ASN/network enrichment.
    Do not hold the caller for a slow third provider.
    """

    providers=tuple(
        DEFAULT_PROVIDERS
    )

    if not providers:
        return []


    executor=ThreadPoolExecutor(
        max_workers=len(providers),
        thread_name_prefix="country-geo",
    )


    futures={
        executor.submit(
            provider,
            ip,
            timeout,
        ):provider
        for provider in providers
    }


    rows=[]
    countries=Counter()

    consensus_reached=False
    consensus_at=None


    def _country_key(
        row: GeoLookup,
    ) -> str | None:

        if not row.success:
            return None

        code=row.country_code

        if not isinstance(code,str):
            return None

        code=code.strip().upper()

        if len(code)!=2:
            return None

        return code


    try:

        pending=set(
            futures.keys()
        )

        while pending:

            # Before consensus, provider timeout is
            # the effective upper bound.
            wait_timeout=(
                timeout + 2.5
            )

            # After consensus, only wait for the
            # bounded evidence grace window.
            if (
                consensus_reached
                and consensus_at
                is not None
            ):
                elapsed=(
                    time.monotonic()
                    - consensus_at
                )

                remaining=(
                    evidence_grace_seconds
                    - elapsed
                )

                if remaining <= 0:
                    break

                wait_timeout=remaining


            try:

                future=next(
                    as_completed(
                        pending,
                        timeout=wait_timeout,
                    )
                )

            except FuturesTimeoutError:
                break


            pending.discard(
                future
            )


            provider=futures[
                future
            ]


            try:
                row=future.result()

            except Exception as exc:

                row=GeoLookup(
                    provider=getattr(
                        provider,
                        "__name__",
                        "unknown",
                    ),
                    success=False,
                    ip=ip,
                    error=(
                        f"{type(exc).__name__}: "
                        f"{exc}"
                    )[:500],
                )


            rows.append(
                row
            )


            key=_country_key(
                row
            )

            if key is not None:

                countries[
                    key
                ]+=1


                if (
                    not consensus_reached
                    and countries[key]
                    >= minimum_agreement
                ):

                    consensus_reached=True
                    consensus_at=(
                        time.monotonic()
                    )


                    # If all providers already
                    # completed, no grace is needed.
                    if not pending:
                        break


        # Collect futures that completed during the
        # grace boundary but were not consumed yet.
        for future in list(
            pending
        ):

            if not future.done():
                continue

            pending.discard(
                future
            )

            provider=futures[
                future
            ]

            try:
                row=future.result()
            except Exception as exc:
                row=GeoLookup(
                    provider=getattr(
                        provider,
                        "__name__",
                        "unknown",
                    ),
                    success=False,
                    ip=ip,
                    error=(
                        f"{type(exc).__name__}: "
                        f"{exc}"
                    )[:500],
                )

            rows.append(row)


        # Cancel futures that have not started.
        # Running curl subprocesses remain bounded by
        # their own provider timeout.
        for future in pending:
            future.cancel()


        return rows


    finally:

        executor.shutdown(
            wait=False,
            cancel_futures=True,
        )
