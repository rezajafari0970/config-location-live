from __future__ import annotations

from .core.models import (
    HealthJob,
    HealthResult,
    HealthState,
    ProbeResult,
)

from .core.policy import finalize_health

from .core.state_machine import (
    InvalidHealthTransition,
    validate_transition,
)


def main() -> int:

    job = HealthJob(
        job_id="ht1-selftest",
        config_id="test-config",
        config_type="vless",
    )

    assert job.state if False else True

    validate_transition(
        HealthState.NEW,
        HealthState.QUEUED,
    )

    validate_transition(
        HealthState.QUEUED,
        HealthState.RUNNING,
    )

    try:
        validate_transition(
            HealthState.NEW,
            HealthState.HEALTHY,
        )
    except InvalidHealthTransition:
        pass
    else:
        raise AssertionError(
            "invalid transition accepted"
        )

    result = HealthResult(
        job_id=job.job_id,
        config_id=job.config_id,
        config_type=job.config_type,
        state=HealthState.RUNNING,
        xray_started=True,
    )

    result.download_results.append(
        ProbeResult(
            provider="selftest-download",
            direction="download",
            success=True,
            bytes_transferred=1024,
            duration_ms=10,
        )
    )

    result.upload_results.append(
        ProbeResult(
            provider="selftest-upload",
            direction="upload",
            success=True,
            bytes_transferred=1024,
            duration_ms=10,
        )
    )

    finalize_health(result)

    assert result.state == HealthState.HEALTHY
    assert result.healthy is True

    bad = HealthResult(
        job_id="bad",
        config_id="bad",
        config_type="vless",
        state=HealthState.RUNNING,
        xray_started=True,
    )

    bad.download_results.append(
        ProbeResult(
            provider="download",
            direction="download",
            success=True,
            bytes_transferred=1024,
        )
    )

    finalize_health(bad)

    assert bad.state == HealthState.UNHEALTHY
    assert bad.healthy is False

    print("[PASS] models")
    print("[PASS] state-machine")
    print("[PASS] health-policy")
    print("[PASS] mandatory-download")
    print("[PASS] mandatory-upload")
    print("[PASS] HT1 foundation selftest")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
