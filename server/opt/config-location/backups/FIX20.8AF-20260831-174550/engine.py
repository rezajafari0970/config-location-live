from __future__ import annotations

import time
from typing import Any

from .decision import apply_health_decision
from .models import (
    HealthResult,
    HealthState,
    ProbeResult,
    utc_now,
)

from ..runtime.launcher import (
    RuntimeLauncher,
    RuntimeLaunchError,
)

from ..probes.download import (
    DEFAULT_TARGETS as DOWNLOAD_TARGETS,
    run_download,
)

from ..probes.upload import (
    DEFAULT_TARGETS as UPLOAD_TARGETS,
    run_upload,
)


class HealthExecutionError(RuntimeError):
    pass


def _download_probe_result(
    measurement,
) -> ProbeResult:

    return ProbeResult(
        provider=measurement.provider,
        direction="download",
        success=measurement.success,
        bytes_transferred=(
            measurement.bytes_transferred
        ),
        duration_ms=measurement.duration_ms,
        error=measurement.error,
        metadata={
            "http_code":
                measurement.http_code,
        },
    )


def _upload_probe_result(
    measurement,
) -> ProbeResult:

    return ProbeResult(
        provider=measurement.provider,
        direction="upload",
        success=measurement.success,
        bytes_transferred=(
            measurement.bytes_transferred
        ),
        duration_ms=measurement.duration_ms,
        error=measurement.error,
        metadata={
            "http_code":
                measurement.http_code,
        },
    )


def run_health_once(
    *,
    config_id: str,
    config_type: str,
    source: Any,
    launcher: RuntimeLauncher | None = None,
    startup_timeout: float = 6.0,
    download_timeout: float = 12.0,
    upload_timeout: float = 15.0,
    upload_payload_bytes: int = 65536,
) -> HealthResult:

    launcher = (
        launcher
        or RuntimeLauncher()
    )

    result = HealthResult(
        job_id=(
            "health-"
            + config_id
            + "-"
            + str(
                time.time_ns()
            )
        ),
        config_id=config_id,
        config_type=config_type,
        state=HealthState.RUNNING,
        started_at=utc_now(),
    )

    runtime = None

    try:
        runtime = launcher.launch(
            config_id=config_id,
            config_type=config_type,
            source=source,
            startup_timeout=startup_timeout,
        )

        result.xray_started = True

        result.metadata[
            "runtime"
        ] = {
            "pid": runtime.pid,
            "socks_port":
                runtime.socks_port,
            "builder":
                runtime.metadata.get(
                    "builder"
                ),
            "protocol":
                runtime.metadata.get(
                    "protocol"
                ),
            "network":
                runtime.metadata.get(
                    "network"
                ),
            "security":
                runtime.metadata.get(
                    "security"
                ),
        }

        # Download fallback chain.
        # Stop as soon as one provider proves
        # download/connectivity successfully.
        for target in DOWNLOAD_TARGETS:

            measurement = run_download(
                target=target,
                proxy_url=runtime.proxy_url,
                timeout_seconds=download_timeout,
            )

            probe = _download_probe_result(
                measurement
            )

            result.download_results.append(
                probe
            )

            if probe.success:
                break

        # Upload fallback chain.
        # Stop as soon as one provider proves
        # real payload transmission.
        for target in UPLOAD_TARGETS:

            measurement = run_upload(
                target=target,
                proxy_url=runtime.proxy_url,
                timeout_seconds=upload_timeout,
                payload_bytes=(
                    upload_payload_bytes
                ),
            )

            probe = _upload_probe_result(
                measurement
            )

            result.upload_results.append(
                probe
            )

            if probe.success:
                break

        # Capture Xray log metadata before
        # sandbox cleanup. We deliberately do
        # not expose raw runtime configuration.
        stdout_path = (
            runtime.sandbox.paths.stdout
        )

        stderr_path = (
            runtime.sandbox.paths.stderr
        )

        result.metadata[
            "xray_logs"
        ] = {
            "stdout_bytes": (
                stdout_path.stat().st_size
                if stdout_path.exists()
                else 0
            ),
            "stderr_bytes": (
                stderr_path.stat().st_size
                if stderr_path.exists()
                else 0
            ),
        }

        apply_health_decision(
            result
        )

    except RuntimeLaunchError as exc:

        result.xray_started = False

        code = getattr(
            exc,
            "code",
            "runtime_launch_failed",
        )

        retryable = bool(
            getattr(
                exc,
                "retryable",
                False,
            )
        )

        source_invalid = bool(
            getattr(
                exc,
                "source_invalid",
                False,
            )
        )

        if code == "unsupported_by_xray":

            result.state = (
                HealthState.UNSUPPORTED_BY_XRAY
            )

        elif code == "unsupported_by_xray_version":

            result.state = (
                HealthState.UNSUPPORTED_BY_XRAY_VERSION
            )

        elif code == "not_tested":

            result.state = (
                HealthState.NOT_TESTED
            )

        elif (
            source_invalid
            or
            code == "invalid"
        ):

            result.state = (
                HealthState.INVALID
            )

        else:

            result.state = (
                HealthState.RUNTIME_FAILED
            )

        result.error_code = code

        result.error_message = str(exc)

        result.metadata[
            "runtime_semantics"
        ] = {
            "state":
                result.state.value,

            "xray_process_started":
                False,

            "traffic_tested":
                False,

            "retryable":
                retryable,
        }

    except Exception as exc:

        result.error_code = (
            type(exc).__name__
        )

        result.error_message = str(exc)

        result.state = HealthState.ERROR

    finally:

        if runtime is not None:

            process = runtime.sandbox.process

            if process is not None:
                result.xray_exit_code = (
                    process.poll()
                )

            runtime.stop()

        result.finished_at = utc_now()

    return result
