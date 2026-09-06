from __future__ import annotations

from .eligibility import (
    decide_country_eligibility,
)

from .models import (
    CountryEvidence,
    CountryState,
    EvidenceKind,
)

from .consensus import (
    decide_country_consensus,
)

from .normalize import (
    country_flag,
    normalize_country_code,
)


def main() -> int:

    assert normalize_country_code("de") == "DE"
    assert country_flag("DE") == "🇩🇪"

    print("[PASS] normalize")

    assert decide_country_eligibility(
        {"state": "healthy"}
    ).eligible is True

    assert decide_country_eligibility(
        {"state": "unhealthy"}
    ).eligible is False

    assert decide_country_eligibility(
        {"state": "error"}
    ).eligible is False

    print("[PASS] eligibility")

    evidence = [
        CountryEvidence(
            provider="geo-a",
            kind=EvidenceKind.GEO_COUNTRY,
            success=True,
            exit_ip="1.2.3.4",
            country_code="DE",
            country_name="Germany",
        ),
        CountryEvidence(
            provider="geo-b",
            kind=EvidenceKind.GEO_COUNTRY,
            success=True,
            exit_ip="1.2.3.4",
            country_code="DE",
            country_name="Germany",
        ),
        CountryEvidence(
            provider="geo-c",
            kind=EvidenceKind.GEO_COUNTRY,
            success=True,
            exit_ip="1.2.3.4",
            country_code="DE",
            country_name="Germany",
        ),
    ]

    r = decide_country_consensus(
        config_id="test",
        evidence=evidence,
    )

    assert r.state == CountryState.CONFIRMED
    assert r.country_code == "DE"
    assert r.country_name == "Germany"
    assert r.flag == "🇩🇪"
    assert r.exit_ip == "1.2.3.4"

    print("[PASS] unanimous consensus")

    conflict = [
        CountryEvidence(
            provider="a",
            kind=EvidenceKind.GEO_COUNTRY,
            success=True,
            country_code="DE",
        ),
        CountryEvidence(
            provider="b",
            kind=EvidenceKind.GEO_COUNTRY,
            success=True,
            country_code="US",
        ),
    ]

    r = decide_country_consensus(
        config_id="conflict",
        evidence=conflict,
    )

    assert r.state == CountryState.AMBIGUOUS

    print("[PASS] ambiguous")

    print("[PASS] FIX22B")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
