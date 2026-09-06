from __future__ import annotations

from collections import Counter

from .geo_providers import (
    lookup_all,
)

from .fallback_geo import (
    lookup_fallback_all,
)

from .normalize import (
    normalize_country_code,
    country_flag,
)

from .rdap_recovery import (
    lookup_rdap,
)


def ultimate_country(
    ip: str,
) -> dict:

    votes=[]

    evidence=[]


    primary=lookup_all(
        ip,
        timeout=8.0,
    )


    for row in primary:

        code=normalize_country_code(
            row.country_code
        )

        evidence.append(
            {
                "provider":
                    row.provider,

                "success":
                    row.success,

                "country_code":
                    code,

                "error":
                    row.error,
            }
        )

        if row.success and code:
            votes.append(
                code
            )


    fallback=lookup_fallback_all(
        ip,
        timeout=8.0,
    )


    for row in fallback:

        code=normalize_country_code(
            row.country_code
        )

        evidence.append(
            {
                "provider":
                    row.provider,

                "success":
                    row.success,

                "country_code":
                    code,

                "error":
                    row.error,
            }
        )

        if row.success and code:
            votes.append(
                code
            )


    rdap=lookup_rdap(
        ip
    )

    rdap_code=normalize_country_code(
        rdap.country_code
    )


    evidence.append(
        {
            "provider":"rdap",

            "success":
                rdap.success,

            "country_code":
                rdap_code,

            "error":
                rdap.error,
        }
    )


    if (
        rdap.success
        and rdap_code
    ):
        votes.append(
            rdap_code
        )


    if not votes:

        return {
            "state":"unknown",

            "country_code":None,

            "flag":None,

            "confidence":0.0,

            "votes":0,

            "agreed":0,

            "evidence":
                evidence,
        }


    counts=Counter(
        votes
    )

    code,agreed=(
        counts.most_common(
            1
        )[0]
    )

    confidence=(
        agreed
        / len(votes)
    )


    # Hard-recovery consensus:
    # at least two independent sources and
    # >60% majority.
    if (
        agreed>=2
        and confidence>=0.60
    ):

        return {
            "state":"confirmed",

            "country_code":
                code,

            "flag":
                country_flag(
                    code
                ),

            "confidence":
                confidence,

            "votes":
                len(votes),

            "agreed":
                agreed,

            "evidence":
                evidence,
        }


    return {
        "state":"ambiguous",

        "country_code":None,

        "flag":None,

        "confidence":
            confidence,

        "votes":
            len(votes),

        "agreed":
            agreed,

        "evidence":
            evidence,
    }
