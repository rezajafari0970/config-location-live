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
