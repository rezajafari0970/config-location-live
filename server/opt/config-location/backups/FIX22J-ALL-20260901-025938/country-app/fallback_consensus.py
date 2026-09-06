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
