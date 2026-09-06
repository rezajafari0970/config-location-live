from __future__ import annotations

from .temporal import (
    decide_temporal,
)


def row(
    ip: str,
    country: str,
) -> dict:

    return {
        "exit_ip":ip,
        "country_code":country,
    }


def main() -> int:

    r=decide_temporal(
        [
            row(
                "1.1.1.1",
                "DE",
            )
        ]
    )

    assert (
        r.state
        ==
        "pending_confirmation"
    )

    print(
        "[PASS] one observation pending"
    )


    r=decide_temporal(
        [
            row(
                "1.1.1.1",
                "DE",
            ),
            row(
                "1.1.1.1",
                "DE",
            ),
        ]
    )

    assert (
        r.state
        ==
        "confirmed_stable"
    )

    print(
        "[PASS] stable country + IP"
    )


    r=decide_temporal(
        [
            row(
                "1.1.1.1",
                "DE",
            ),
            row(
                "2.2.2.2",
                "DE",
            ),
        ]
    )

    assert (
        r.state
        ==
        "confirmed_rotating_ip"
    )

    assert (
        r.country_code
        == "DE"
    )

    print(
        "[PASS] rotating IP same country"
    )


    r=decide_temporal(
        [
            row(
                "1.1.1.1",
                "DE",
            ),
            row(
                "2.2.2.2",
                "US",
            ),
        ]
    )

    assert (
        r.state
        == "rotating"
    )

    assert (
        r.country_code
        is None
    )

    print(
        "[PASS] rotating country detected"
    )


    print(
        "[PASS] FIX22E temporal engine"
    )

    return 0


if __name__=="__main__":
    raise SystemExit(
        main()
    )
