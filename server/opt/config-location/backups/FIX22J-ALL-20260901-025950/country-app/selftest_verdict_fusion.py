from __future__ import annotations

from .verdict_fusion import (
    fuse_country_verdict,
)


def main() -> int:

    # Strong primary retained.
    r=fuse_country_verdict(
        primary={
            "state":"confirmed",
            "country_code":"DE",
            "country_name":"Germany",
            "flag":"🇩🇪",
            "country_confidence":1.0,
        },
        recovery=None,
    )

    assert r.state=="confirmed"
    assert r.country_code=="DE"
    assert r.source=="primary"

    print(
        "[PASS] strong primary retained"
    )


    # Weak/unknown primary recovered.
    r=fuse_country_verdict(
        primary={
            "state":"unknown",
            "country_code":None,
            "country_confidence":0.0,
        },
        recovery={
            "state":"confirmed",
            "country_code":"DE",
            "country_name":"Germany",
            "flag":"🇩🇪",
            "confidence":1.0,
        },
    )

    assert r.state=="confirmed"
    assert r.country_code=="DE"
    assert r.source=="recovery"

    print(
        "[PASS] unknown recovered"
    )


    # Strong disagreement must never pick one side.
    r=fuse_country_verdict(
        primary={
            "state":"confirmed",
            "country_code":"DE",
            "country_confidence":1.0,
        },
        recovery={
            "state":"confirmed",
            "country_code":"US",
            "confidence":1.0,
        },
    )

    assert r.state=="ambiguous"
    assert r.country_code is None
    assert r.conflict is True

    print(
        "[PASS] strong conflict blocked"
    )


    # Weak signal conflict also blocked.
    r=fuse_country_verdict(
        primary={
            "state":"ambiguous",
            "country_code":"DE",
            "country_confidence":0.5,
        },
        recovery={
            "state":"confirmed",
            "country_code":"US",
            "confidence":1.0,
        },
    )

    assert r.state=="ambiguous"
    assert r.country_code is None

    print(
        "[PASS] weak conflict blocked"
    )


    # No evidence remains unknown.
    r=fuse_country_verdict(
        primary={
            "state":"unknown",
            "country_code":None,
        },
        recovery={
            "state":"unknown",
            "country_code":None,
        },
    )

    assert r.state=="unknown"

    print(
        "[PASS] unknown remains unknown"
    )


    # Temporal rotation is preserved.
    r=fuse_country_verdict(
        primary={
            "state":"rotating",
            "country_code":None,
        },
        recovery=None,
    )

    assert r.state=="rotating"

    print(
        "[PASS] rotation preserved"
    )


    print(
        "[PASS] FIX22F2 verdict fusion"
    )

    return 0


if __name__=="__main__":
    raise SystemExit(
        main()
    )
