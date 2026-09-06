from __future__ import annotations

import json
import subprocess
import time

from concurrent.futures import (
    ThreadPoolExecutor,
    as_completed,
)

from dataclasses import dataclass
from typing import Any


@dataclass
class RecoveryEvidence:

    provider: str

    success: bool

    country_code: str | None = None
    country_name: str | None = None

    asn: str | None = None
    network_name: str | None = None

    evidence_type: str = "geo"

    error: str | None = None

    duration_ms: int = 0


def _curl_json(
    url: str,
    timeout: float,
) -> dict[str,Any]:

    result=subprocess.run(
        [
            "curl",
            "-4",
            "-fsSL",
            "--max-time",
            str(timeout),
            "-H",
            "Accept: application/json",
            url,
        ],
        capture_output=True,
        text=True,
        timeout=timeout+2,
    )

    if result.returncode!=0:

        raise RuntimeError(
            (
                result.stderr
                or "curl failed"
            )[:500]
        )

    obj=json.loads(
        result.stdout
    )

    if not isinstance(obj,dict):
        raise RuntimeError(
            "response is not object"
        )

    return obj


def _norm_country(
    value: Any,
) -> str | None:

    if not isinstance(
        value,
        str,
    ):
        return None

    value=value.strip().upper()

    if len(value)!=2:
        return None

    if not value.isalpha():
        return None

    return value


def lookup_dbip(
    ip: str,
    timeout: float = 4.0,
) -> RecoveryEvidence:

    started=time.monotonic()

    try:

        o=_curl_json(
            "https://api.db-ip.com/v2/free/"
            +ip,
            timeout,
        )

        code=_norm_country(
            o.get("countryCode")
        )

        if not code:

            raise RuntimeError(
                "countryCode missing"
            )

        return RecoveryEvidence(
            provider="db-ip",
            success=True,
            country_code=code,
            country_name=o.get(
                "countryName"
            ),
            evidence_type="geo",
            duration_ms=int(
                (
                    time.monotonic()
                    -started
                )*1000
            ),
        )

    except Exception as exc:

        return RecoveryEvidence(
            provider="db-ip",
            success=False,
            error=(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:500],
            evidence_type="geo",
            duration_ms=int(
                (
                    time.monotonic()
                    -started
                )*1000
            ),
        )


def lookup_ipinfo(
    ip: str,
    timeout: float = 4.0,
) -> RecoveryEvidence:

    started=time.monotonic()

    try:

        o=_curl_json(
            "https://ipinfo.io/"
            +ip
            +"/json",
            timeout,
        )

        code=_norm_country(
            o.get("country")
        )

        if not code:

            raise RuntimeError(
                "country missing"
            )

        org=str(
            o.get("org")
            or ""
        ).strip()

        asn=None
        network=None

        if org:

            parts=org.split(
                " ",
                1,
            )

            if (
                parts
                and parts[0]
                .upper()
                .startswith("AS")
            ):
                asn=parts[0].upper()

                if len(parts)>1:
                    network=parts[1]


        return RecoveryEvidence(
            provider="ipinfo",
            success=True,
            country_code=code,
            asn=asn,
            network_name=network,
            evidence_type="geo",
            duration_ms=int(
                (
                    time.monotonic()
                    -started
                )*1000
            ),
        )

    except Exception as exc:

        return RecoveryEvidence(
            provider="ipinfo",
            success=False,
            error=(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:500],
            evidence_type="geo",
            duration_ms=int(
                (
                    time.monotonic()
                    -started
                )*1000
            ),
        )


def lookup_rdap(
    ip: str,
    timeout: float = 5.0,
) -> RecoveryEvidence:

    started=time.monotonic()

    try:

        o=_curl_json(
            "https://rdap.org/ip/"
            +ip,
            timeout,
        )

        code=_norm_country(
            o.get("country")
        )

        name=(
            o.get("name")
            or o.get("handle")
        )

        return RecoveryEvidence(
            provider="rdap",
            success=bool(code),
            country_code=code,
            network_name=(
                str(name)
                if name
                else None
            ),
            evidence_type="registry",
            error=(
                None
                if code
                else "RDAP country missing"
            ),
            duration_ms=int(
                (
                    time.monotonic()
                    -started
                )*1000
            ),
        )

    except Exception as exc:

        return RecoveryEvidence(
            provider="rdap",
            success=False,
            evidence_type="registry",
            error=(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:500],
            duration_ms=int(
                (
                    time.monotonic()
                    -started
                )*1000
            ),
        )


def recover_country(
    ip: str,
    timeout: float = 5.0,
) -> dict:

    providers=(
        lookup_dbip,
        lookup_ipinfo,
        lookup_rdap,
    )

    rows=[]

    with ThreadPoolExecutor(
        max_workers=3,
        thread_name_prefix="k7-recovery",
    ) as executor:

        futures={
            executor.submit(
                p,
                ip,
                timeout,
            ):p
            for p in providers
        }

        for future in as_completed(
            futures
        ):

            try:
                rows.append(
                    future.result()
                )
            except Exception as exc:

                p=futures[future]

                rows.append(
                    RecoveryEvidence(
                        provider=p.__name__,
                        success=False,
                        error=(
                            f"{type(exc).__name__}: "
                            f"{exc}"
                        )[:500],
                    )
                )


    geo=[
        r
        for r in rows
        if (
            r.success
            and r.evidence_type=="geo"
            and r.country_code
        )
    ]

    registry=[
        r
        for r in rows
        if (
            r.success
            and r.evidence_type=="registry"
            and r.country_code
        )
    ]


    geo_codes=[
        r.country_code
        for r in geo
    ]


    confirmed=None
    reason="insufficient_independent_evidence"


    # Strongest path:
    # two independent physical Geo providers agree.
    if (
        len(geo_codes)>=2
        and len(
            set(geo_codes)
        )==1
    ):

        confirmed=geo_codes[0]

        reason="two_independent_geo_agree"


    # Secondary path:
    # one Geo source + independent RDAP registry.
    elif (
        len(geo_codes)==1
        and registry
        and any(
            r.country_code
            ==geo_codes[0]
            for r in registry
        )
    ):

        confirmed=geo_codes[0]

        reason="geo_plus_rdap_agree"


    country_name=None
    asn=None
    network_name=None


    if confirmed:

        for r in rows:

            if (
                r.country_code
                !=confirmed
            ):
                continue

            if (
                country_name is None
                and r.country_name
            ):
                country_name=(
                    r.country_name
                )

            if (
                asn is None
                and r.asn
            ):
                asn=r.asn

            if (
                network_name is None
                and r.network_name
            ):
                network_name=(
                    r.network_name
                )


    return {
        "state":(
            "confirmed"
            if confirmed
            else "ambiguous"
        ),

        "country_code":
            confirmed,

        "country_name":
            country_name,

        "asn":
            asn,

        "network_name":
            network_name,

        "network_type":
            None,

        "country_confidence":(
            0.92
            if reason
            =="two_independent_geo_agree"
            else (
                0.80
                if confirmed
                else 0.0
            )
        ),

        "recovery_reason":
            reason,

        "recovery_evidence":[
            {
                "provider":
                    r.provider,

                "success":
                    r.success,

                "country_code":
                    r.country_code,

                "country_name":
                    r.country_name,

                "asn":
                    r.asn,

                "network_name":
                    r.network_name,

                "evidence_type":
                    r.evidence_type,

                "error":
                    r.error,

                "duration_ms":
                    r.duration_ms,
            }
            for r in rows
        ],
    }
