from __future__ import annotations

from .decision import (
    apply_health_decision,
    decide_health,
)

from .models import (
    HealthResult,
    HealthState,
    ProbeResult,
)


def probe(
    provider: str,
    direction: str,
    success: bool,
    size: int = 65536,
) -> ProbeResult:

    return ProbeResult(
        provider=provider,
        direction=direction,
        success=success,
        bytes_transferred=size,
        duration_ms=100,
    )


def main() -> int:

    # Case 1:
    # Exactly one provider in each direction.
    d = decide_health(
        xray_started=True,
        download_results=[
            probe(
                "cloudflare",
                "download",
                True,
            ),
            probe(
                "google",
                "download",
                False,
                0,
            ),
            probe(
                "microsoft",
                "download",
                False,
                0,
            ),
        ],
        upload_results=[
            probe(
                "cloudflare",
                "upload",
                False,
                0,
            ),
            probe(
                "google",
                "upload",
                True,
            ),
            probe(
                "microsoft",
                "upload",
                False,
                0,
            ),
        ],
    )

    assert d.healthy is True
    assert d.download_success_count == 1
    assert d.upload_success_count == 1

    print(
        "[PASS] one download provider is enough"
    )

    print(
        "[PASS] one upload provider is enough"
    )

    print(
        "[PASS] providers may be different"
    )

    # Case 2:
    # All 3 download providers succeed but
    # no upload succeeds => unhealthy.
    d = decide_health(
        xray_started=True,
        download_results=[
            probe(
                "cloudflare",
                "download",
                True,
            ),
            probe(
                "google",
                "download",
                True,
                0,
            ),
            probe(
                "microsoft",
                "download",
                True,
            ),
        ],
        upload_results=[
            probe(
                "cloudflare",
                "upload",
                False,
                0,
            ),
            probe(
                "google",
                "upload",
                False,
                0,
            ),
            probe(
                "microsoft",
                "upload",
                False,
                0,
            ),
        ],
    )

    assert d.healthy is False
    assert d.reason == "upload_failed"

    print(
        "[PASS] download alone is not enough"
    )

    # Case 3:
    # Upload success without download.
    d = decide_health(
        xray_started=True,
        download_results=[],
        upload_results=[
            probe(
                "cloudflare",
                "upload",
                True,
            )
        ],
    )

    assert d.healthy is False
    assert d.reason == "download_failed"

    print(
        "[PASS] upload alone is not enough"
    )

    # Case 4:
    # Traffic succeeds but Xray was not
    # successfully started.
    d = decide_health(
        xray_started=False,
        download_results=[
            probe(
                "cloudflare",
                "download",
                True,
            )
        ],
        upload_results=[
            probe(
                "cloudflare",
                "upload",
                True,
            )
        ],
    )

    assert d.healthy is False
    assert d.reason == "xray_failed"

    print(
        "[PASS] Xray runtime is mandatory"
    )

    # Case 5:
    # Apply to HealthResult.
    result = HealthResult(
        job_id="ht7-selftest",
        config_id="config-test",
        config_type="vless",
        state=HealthState.RUNNING,
        xray_started=True,
    )

    result.download_results.extend([
        probe(
            "cloudflare",
            "download",
            False,
            0,
        ),
        probe(
            "microsoft",
            "download",
            True,
        ),
    ])

    result.upload_results.extend([
        probe(
            "google",
            "upload",
            True,
        ),
    ])

    apply_health_decision(
        result
    )

    assert (
        result.state
        == HealthState.HEALTHY
    )

    assert (
        result.download_verified
        is True
    )

    assert (
        result.upload_verified
        is True
    )

    assert (
        result.metadata[
            "health_decision"
        ][
            "download_success_count"
        ]
        == 1
    )

    assert (
        result.metadata[
            "health_decision"
        ][
            "upload_success_count"
        ]
        == 1
    )

    print(
        "[PASS] HealthResult integration"
    )

    print(
        "[PASS] HT7 decision engine"
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
