from __future__ import annotations

import json
import subprocess
import time

from concurrent.futures import (
    ThreadPoolExecutor,
    as_completed,
)

from collections import Counter


def _curl_json(
    url: str,
    timeout: float=6.0,
) -> dict:

    r=subprocess.run(
        [
            "curl",
            "-fsSL",
            "--max-time",
            str(timeout),
            "-H",
            "Accept: application/json",
            "-H",
            "User-Agent: config-location-k7e/1",
            url,
        ],
        capture_output=True,
        text=True,
        timeout=timeout+2,
    )

    if r.returncode!=0:
        raise RuntimeError(
            (
                r.stderr
                or "curl failed"
            )[:500]
        )

    o=json.loads(
        r.stdout
    )

    if not isinstance(o,dict):
        raise RuntimeError(
            "response_not_object"
        )

    return o


def _cc(v):
    if not isinstance(v,str):
        return None

    v=v.strip().upper()

    if (
        len(v)==2
        and v.isalpha()
    ):
        return v

    return None


def _evidence(
    *,
    provider,
    evidence_type,
    country_code=None,
    country_name=None,
    asn=None,
    network_name=None,
    success=False,
    error=None,
    duration_ms=0,
):

    return {
        "provider":provider,
        "evidence_type":evidence_type,
        "success":bool(success),
        "country_code":country_code,
        "country_name":country_name,
        "asn":asn,
        "network_name":network_name,
        "error":error,
        "duration_ms":duration_ms,
    }


def dbip(ip):

    t=time.monotonic()

    try:
        o=_curl_json(
            "https://api.db-ip.com/v2/free/"
            +ip
        )

        code=_cc(
            o.get("countryCode")
        )

        if not code:
            raise RuntimeError(
                "countryCode_missing"
            )

        return _evidence(
            provider="db-ip",
            evidence_type="geo",
            success=True,
            country_code=code,
            country_name=o.get(
                "countryName"
            ),
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )

    except Exception as exc:
        return _evidence(
            provider="db-ip",
            evidence_type="geo",
            error=(
                f"{type(exc).__name__}: {exc}"
            )[:500],
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )


def ipinfo(ip):

    t=time.monotonic()

    try:
        o=_curl_json(
            "https://ipinfo.io/"
            +ip
            +"/json"
        )

        code=_cc(
            o.get("country")
        )

        if not code:
            raise RuntimeError(
                "country_missing"
            )

        org=str(
            o.get("org")
            or ""
        ).strip()

        asn=None
        network=None

        if org:
            parts=org.split(" ",1)

            if (
                parts
                and parts[0]
                .upper()
                .startswith("AS")
            ):
                asn=parts[0].upper()

                if len(parts)>1:
                    network=parts[1]

        return _evidence(
            provider="ipinfo",
            evidence_type="geo",
            success=True,
            country_code=code,
            asn=asn,
            network_name=network,
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )

    except Exception as exc:
        return _evidence(
            provider="ipinfo",
            evidence_type="geo",
            error=(
                f"{type(exc).__name__}: {exc}"
            )[:500],
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )


def ipwhois(ip):

    t=time.monotonic()

    try:
        o=_curl_json(
            "https://ipwho.is/"
            +ip
        )

        if o.get("success") is False:
            raise RuntimeError(
                str(
                    o.get("message")
                    or "provider_failure"
                )
            )

        code=_cc(
            o.get("country_code")
        )

        if not code:
            raise RuntimeError(
                "country_code_missing"
            )

        conn=o.get(
            "connection"
        ) or {}

        return _evidence(
            provider="ipwho.is",
            evidence_type="geo",
            success=True,
            country_code=code,
            country_name=o.get(
                "country"
            ),
            asn=(
                str(conn.get("asn"))
                if conn.get("asn")
                else None
            ),
            network_name=conn.get(
                "org"
            ),
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )

    except Exception as exc:
        return _evidence(
            provider="ipwho.is",
            evidence_type="geo",
            error=(
                f"{type(exc).__name__}: {exc}"
            )[:500],
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )


def ipapi(ip):

    t=time.monotonic()

    try:
        o=_curl_json(
            "https://ipapi.co/"
            +ip
            +"/json/"
        )

        code=_cc(
            o.get("country_code")
            or o.get("country")
        )

        if not code:
            raise RuntimeError(
                str(
                    o.get("reason")
                    or "country_missing"
                )
            )

        asn=o.get("asn")

        return _evidence(
            provider="ipapi.co",
            evidence_type="geo",
            success=True,
            country_code=code,
            country_name=o.get(
                "country_name"
            ),
            asn=(
                str(asn)
                if asn
                else None
            ),
            network_name=o.get("org"),
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )

    except Exception as exc:
        return _evidence(
            provider="ipapi.co",
            evidence_type="geo",
            error=(
                f"{type(exc).__name__}: {exc}"
            )[:500],
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )


def rdap(ip):

    t=time.monotonic()

    try:
        o=_curl_json(
            "https://rdap.org/ip/"
            +ip
        )

        code=_cc(
            o.get("country")
        )

        if not code:
            raise RuntimeError(
                "rdap_country_missing"
            )

        return _evidence(
            provider="rdap",
            evidence_type="registry",
            success=True,
            country_code=code,
            network_name=(
                o.get("name")
                or o.get("handle")
            ),
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )

    except Exception as exc:
        return _evidence(
            provider="rdap",
            evidence_type="registry",
            error=(
                f"{type(exc).__name__}: {exc}"
            )[:500],
            duration_ms=int(
                (time.monotonic()-t)*1000
            ),
        )


def recover(ip: str) -> dict:

    funcs=(
        dbip,
        ipinfo,
        ipwhois,
        ipapi,
        rdap,
    )

    evidence=[]

    with ThreadPoolExecutor(
        max_workers=5,
        thread_name_prefix="k7e-ip",
    ) as ex:

        futures={
            ex.submit(fn,ip):fn
            for fn in funcs
        }

        for f in as_completed(
            futures
        ):
            try:
                evidence.append(
                    f.result()
                )
            except Exception as exc:
                evidence.append(
                    _evidence(
                        provider=futures[
                            f
                        ].__name__,
                        evidence_type="unknown",
                        error=str(exc)[:500],
                    )
                )


    geo=[
        e
        for e in evidence
        if (
            e["success"]
            and e["evidence_type"]
            =="geo"
            and e["country_code"]
        )
    ]

    registry=[
        e
        for e in evidence
        if (
            e["success"]
            and e["evidence_type"]
            =="registry"
            and e["country_code"]
        )
    ]


    counts=Counter(
        e["country_code"]
        for e in geo
    )

    winner=None
    winner_count=0

    if counts:
        winner,winner_count=(
            counts.most_common(1)[0]
        )


    confirmed=False
    reason="insufficient_consensus"


    # Strong hard-fallback consensus.
    if (
        winner
        and winner_count>=3
    ):
        confirmed=True
        reason="three_geo_consensus"


    # Two independent Geo + independent registry
    # confirmation. RDAP may support but never
    # establishes Country alone.
    elif (
        winner
        and winner_count>=2
        and any(
            e["country_code"]==winner
            for e in registry
        )
    ):
        confirmed=True
        reason="two_geo_plus_rdap"


    country_name=None
    asn=None
    network_name=None

    if confirmed:

        for e in evidence:

            if e.get(
                "country_code"
            )!=winner:
                continue

            if (
                country_name is None
                and e.get(
                    "country_name"
                )
            ):
                country_name=e[
                    "country_name"
                ]

            if (
                asn is None
                and e.get("asn")
            ):
                asn=e["asn"]

            if (
                network_name is None
                and e.get(
                    "network_name"
                )
            ):
                network_name=e[
                    "network_name"
                ]


    return {
        "state":(
            "confirmed"
            if confirmed
            else "ambiguous"
        ),

        "country_code":(
            winner
            if confirmed
            else None
        ),

        "country_name":
            country_name,

        "asn":
            asn,

        "network_name":
            network_name,

        "network_type":
            None,

        "country_confidence":(
            0.97
            if reason=="three_geo_consensus"
            else (
                0.90
                if confirmed
                else 0.0
            )
        ),

        "recovery_reason":
            reason,

        "geo_vote_counts":
            dict(counts),

        "geo_success_count":
            len(geo),

        "evidence":
            evidence,
    }
