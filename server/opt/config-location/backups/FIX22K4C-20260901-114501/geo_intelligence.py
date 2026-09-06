from __future__ import annotations

from collections import Counter

from .consensus import (
    decide_country_consensus,
)

from .geo_cache import (
    geo_singleflight_lock,
    load_geo_cache,
    save_geo_cache,
)

from .geo_consensus import (
    geo_to_evidence,
)

from .geo_providers import (
    lookup_all,
)

from .network_classifier import (
    classify_network,
)


def resolve_geo(
    *,
    config_id: str,
    ip: str,
    cache_ttl_seconds: int = 604800,
) -> dict:

    # Fast lock-free cache hit.
    cached=load_geo_cache(
        ip=ip,
        ttl_seconds=cache_ttl_seconds,
    )

    if cached is not None:

        return {
            **cached,
            "cache_hit":True,
            "singleflight_role":
                "cache_hit",
        }


    # Cache miss: serialize only this IP.
    with geo_singleflight_lock(
        ip=ip,
    ):

        # Critical double-check.
        # Another process may have populated
        # the cache while we waited.
        cached=load_geo_cache(
            ip=ip,
            ttl_seconds=cache_ttl_seconds,
        )

        if cached is not None:

            return {
                **cached,
                "cache_hit":True,
                "singleflight_role":
                    "waiter_cache_hit",
            }


        result=_resolve_geo_uncached(
            config_id=config_id,
            ip=ip,
            cache_ttl_seconds=
                cache_ttl_seconds,
        )

        return {
            **result,
            "singleflight_role":
                "owner",
        }


def _resolve_geo_uncached(
    *,
    config_id: str,
    ip: str,
    cache_ttl_seconds: int = 604800,
) -> dict:

    # FIX22K4_SINGLEFLIGHT_OWNER
    rows=lookup_all(
        ip,
        timeout=8.0,
    )

    evidence=geo_to_evidence(
        rows
    )

    country=(
        decide_country_consensus(
            config_id=config_id,
            evidence=evidence,
            minimum_agreement=2,
        )
    )


    successful=[
        row
        for row in rows
        if row.success
    ]


    asns=Counter(
        str(row.asn)
        for row in successful
        if row.asn
    )

    networks=Counter(
        str(row.network_name)
        for row in successful
        if row.network_name
    )


    asn=None
    asn_agreed=0

    if asns:
        asn,asn_agreed=(
            asns.most_common(1)[0]
        )


    network_name=None
    network_agreed=0

    if networks:
        (
            network_name,
            network_agreed,
        )=networks.most_common(1)[0]


    classification=(
        classify_network(
            network_name=network_name
        )
    )


    provider_rows=[]

    for row in rows:

        provider_rows.append(
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
        )


    result={
        "schema_version":1,

        "ip":ip,

        "state":
            country.state.value,

        "country_code":
            country.country_code,

        "country_name":
            country.country_name,

        "flag":
            country.flag,

        "country_confidence":
            country.confidence,

        "country_agreed":
            country.providers_agreed,

        "country_total":
            country.providers_total,

        "asn":
            asn,

        "asn_agreed":
            asn_agreed,

        "network_name":
            network_name,

        "network_agreed":
            network_agreed,

        "network_type":
            classification.network_type,

        "network_confidence":
            classification.confidence,

        "network_signals":
            list(
                classification.signals
            ),

        "providers":
            provider_rows,

        "cache_hit":
            False,
    }


    if (
        country.state.value
        == "confirmed"
    ):
        save_geo_cache(
            ip=ip,
            value=result,
        )


    return result
