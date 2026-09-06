from __future__ import annotations

from collections import Counter

from .models import (
    CountryEvidence,
    CountryResult,
    CountryState,
)

from .normalize import (
    country_flag,
    normalize_country_code,
    normalize_country_name,
)


def decide_country_consensus(
    *,
    config_id: str,
    evidence: list[CountryEvidence],
    minimum_agreement: int = 2,
) -> CountryResult:

    usable = [
        item
        for item in evidence
        if (
            item.success
            and normalize_country_code(
                item.country_code
            ) is not None
        )
    ]

    if not usable:
        return CountryResult(
            config_id=config_id,
            state=CountryState.UNKNOWN,
            confidence=0.0,
            method="geo_consensus",
            providers_total=len(evidence),
            reason="no_usable_country_evidence",
            evidence=tuple(evidence),
        )

    counts = Counter(
        normalize_country_code(item.country_code)
        for item in usable
    )

    code, agreed = counts.most_common(1)[0]

    total = len(usable)

    confidence = agreed / total

    names = [
        normalize_country_name(item.country_name)
        for item in usable
        if normalize_country_code(item.country_code) == code
    ]

    names = [x for x in names if x]

    country_name = (
        Counter(names).most_common(1)[0][0]
        if names
        else None
    )

    ips = {
        item.exit_ip
        for item in usable
        if item.exit_ip
    }

    exit_ip = (
        next(iter(ips))
        if len(ips) == 1
        else None
    )

    if agreed >= minimum_agreement and confidence >= 0.67:
        state = CountryState.CONFIRMED
        reason = "country_consensus"
    else:
        state = CountryState.AMBIGUOUS
        reason = "country_provider_disagreement"

    return CountryResult(
        config_id=config_id,
        state=state,
        country_code=code if state == CountryState.CONFIRMED else None,
        country_name=country_name if state == CountryState.CONFIRMED else None,
        flag=country_flag(code) if state == CountryState.CONFIRMED else None,
        exit_ip=exit_ip,
        confidence=confidence,
        method="geo_consensus",
        providers_agreed=agreed,
        providers_total=total,
        reason=reason,
        evidence=tuple(evidence),
    )
