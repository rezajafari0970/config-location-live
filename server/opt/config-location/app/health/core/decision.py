from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .models import (
    HealthResult,
    HealthState,
    ProbeResult,
)


@dataclass(frozen=True)
class HealthDecision:
    healthy: bool
    xray_ok: bool
    download_ok: bool
    upload_ok: bool

    download_success_count: int
    upload_success_count: int

    reason: str
    metadata: dict[str, Any] = field(
        default_factory=dict
    )


def _qualified(
    results: list[ProbeResult],
) -> list[ProbeResult]:

    qualified = []

    for result in results:

        if not result.success:
            continue

        # Real traffic must have been observed.
        # For download, a provider such as
        # Google generate_204 may legitimately
        # return 0 bytes. Therefore success is
        # trusted from the probe plugin itself.
        #
        # Upload plugins only set success=True
        # after payload bytes were actually sent.
        qualified.append(result)

    return qualified


def decide_health(
    *,
    xray_started: bool,
    download_results: list[ProbeResult],
    upload_results: list[ProbeResult],
) -> HealthDecision:

    downloads = _qualified(
        download_results
    )

    uploads = _qualified(
        upload_results
    )

    xray_ok = bool(
        xray_started
    )

    download_ok = (
        len(downloads) >= 1
    )

    upload_ok = (
        len(uploads) >= 1
    )

    healthy = (
        xray_ok
        and download_ok
        and upload_ok
    )

    if healthy:
        reason = "healthy"

    elif not xray_ok:
        reason = "xray_failed"

    elif not download_ok:
        reason = "download_failed"

    elif not upload_ok:
        reason = "upload_failed"

    else:
        reason = "unhealthy"

    return HealthDecision(
        healthy=healthy,
        xray_ok=xray_ok,
        download_ok=download_ok,
        upload_ok=upload_ok,
        download_success_count=len(
            downloads
        ),
        upload_success_count=len(
            uploads
        ),
        reason=reason,
    )


def apply_health_decision(
    result: HealthResult,
) -> HealthResult:

    decision = decide_health(
        xray_started=(
            result.xray_started
        ),
        download_results=(
            result.download_results
        ),
        upload_results=(
            result.upload_results
        ),
    )

    result.download_verified = (
        decision.download_ok
    )

    result.upload_verified = (
        decision.upload_ok
    )

    result.metadata[
        "health_decision"
    ] = {
        "healthy":
            decision.healthy,

        "xray_ok":
            decision.xray_ok,

        "download_ok":
            decision.download_ok,

        "upload_ok":
            decision.upload_ok,

        "download_success_count":
            decision.download_success_count,

        "upload_success_count":
            decision.upload_success_count,

        "reason":
            decision.reason,
    }

    if decision.healthy:
        result.state = (
            HealthState.HEALTHY
        )
    else:
        result.state = (
            HealthState.UNHEALTHY
        )

    return result
