from __future__ import annotations

from .models import (
    HealthResult,
    HealthState,
    ProbeResult,
)


def successful_provider_exists(
    results: list[ProbeResult],
) -> bool:

    return any(
        result.success
        and result.bytes_transferred > 0
        for result in results
    )


def finalize_health(
    result: HealthResult,
) -> HealthResult:

    result.download_verified = (
        successful_provider_exists(
            result.download_results
        )
    )

    result.upload_verified = (
        successful_provider_exists(
            result.upload_results
        )
    )

    if (
        result.xray_started
        and result.download_verified
        and result.upload_verified
    ):
        result.state = HealthState.HEALTHY
    else:
        result.state = HealthState.UNHEALTHY

    return result
