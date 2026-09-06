from __future__ import annotations

import random
import time

from dataclasses import dataclass

from .models import (
    HealthResult,
    HealthState,
)

from .engine import (
    run_health_once,
)


RETRYABLE_ERROR_CODES = {
    "SandboxPortError",
    "runtime_launch_failed",
}


@dataclass(frozen=True)
class RetryExecution:
    result: HealthResult
    retries_used: int
    retry_reason: str | None


def is_retryable_result(
    result: HealthResult,
) -> bool:

    if result.state not in {
        HealthState.ERROR,
        HealthState.RUNTIME_FAILED,
    }:
        return False

    code = (
        result.error_code
        or ""
    )

    if code in RETRYABLE_ERROR_CODES:
        return True

    message = (
        result.error_message
        or ""
    ).lower()

    retry_markers = (
        "sandboxporterror",
        "port allocation",
        "failed to allocate",
        "address already in use",
        "port unavailable",
    )

    return any(
        marker in message
        for marker in retry_markers
    )


def run_health_with_retry(
    *,
    config_id: str,
    config_type: str,
    source,
    startup_timeout: float,
    download_timeout: float,
    upload_timeout: float,
    upload_payload_bytes: int,
    retry_count: int,
    jitter_min: float = 0.05,
    jitter_max: float = 0.35,
) -> RetryExecution:

    retries_used = 0
    retry_reason = None

    for attempt in range(
        retry_count + 1
    ):

        result = run_health_once(
            config_id=config_id,
            config_type=config_type,
            source=source,

            startup_timeout=(
                startup_timeout
            ),

            download_timeout=(
                download_timeout
            ),

            upload_timeout=(
                upload_timeout
            ),

            upload_payload_bytes=(
                upload_payload_bytes
            ),
        )

        if not is_retryable_result(
            result
        ):
            return RetryExecution(
                result=result,
                retries_used=retries_used,
                retry_reason=retry_reason,
            )

        retry_reason = (
            result.error_code
            or "retryable_runtime_error"
        )

        if attempt >= retry_count:
            return RetryExecution(
                result=result,
                retries_used=retries_used,
                retry_reason=retry_reason,
            )

        retries_used += 1

        time.sleep(
            random.uniform(
                jitter_min,
                jitter_max,
            )
        )

    raise RuntimeError(
        "retry loop exhausted unexpectedly"
    )
