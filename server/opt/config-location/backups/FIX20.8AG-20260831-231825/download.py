from __future__ import annotations

import subprocess
import time
from dataclasses import dataclass
from pathlib import Path



def _run_cancellable(
    command,
    *,
    timeout_seconds: float,
    cancel_check=None,
):
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    deadline = (
        time.monotonic()
        + timeout_seconds
    )

    try:
        while True:
            if (
                cancel_check is not None
                and cancel_check()
            ):
                process.terminate()

                try:
                    process.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=1.0)

                raise InterruptedError(
                    "probe_cancelled"
                )

            if process.poll() is not None:
                stdout, stderr = (
                    process.communicate()
                )

                return subprocess.CompletedProcess(
                    command,
                    process.returncode,
                    stdout,
                    stderr,
                )

            if time.monotonic() >= deadline:
                process.terminate()

                try:
                    process.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=1.0)

                raise subprocess.TimeoutExpired(
                    command,
                    timeout_seconds,
                )

            time.sleep(0.05)

    except BaseException:
        if process.poll() is None:
            process.kill()

            try:
                process.wait(timeout=1.0)
            except Exception:
                pass

        raise


@dataclass(frozen=True)
class DownloadTarget:
    provider: str
    url: str
    minimum_bytes: int = 1


@dataclass(frozen=True)
class DownloadMeasurement:
    provider: str
    success: bool
    bytes_transferred: int
    duration_ms: int
    http_code: int | None
    error: str | None


DEFAULT_TARGETS = (
    DownloadTarget(
        provider="cloudflare",
        url=(
            "https://speed.cloudflare.com/"
            "__down?bytes=131072"
        ),
        minimum_bytes=32768,
    ),

    DownloadTarget(
        provider="google",
        url=(
            "https://www.google.com/"
            "generate_204"
        ),
        minimum_bytes=0,
    ),

    DownloadTarget(
        provider="microsoft",
        url=(
            "https://www.microsoft.com/"
            "favicon.ico"
        ),
        minimum_bytes=100,
    ),
)


def run_download(
    *,
    target: DownloadTarget,
    proxy_url: str,
    timeout_seconds: float = 12.0,
    cancel_check=None,
) -> DownloadMeasurement:

    start = time.monotonic()

    command = [
        "curl",
        "--silent",
        "--show-error",
        "--location",
        "--proxy",
        proxy_url,
        "--connect-timeout",
        str(min(6.0, timeout_seconds)),
        "--max-time",
        str(timeout_seconds),
        "--output",
        "/dev/null",
        "--write-out",
        "%{http_code} %{size_download}",
        target.url,
    ]

    try:
        result = _run_cancellable(
            command,
            timeout_seconds=(
                timeout_seconds + 3
            ),
            cancel_check=cancel_check,
        )

    except subprocess.TimeoutExpired:
        return DownloadMeasurement(
            provider=target.provider,
            success=False,
            bytes_transferred=0,
            duration_ms=int(
                (time.monotonic() - start)
                * 1000
            ),
            http_code=None,
            error="process_timeout",
        )

    duration = int(
        (time.monotonic() - start)
        * 1000
    )

    http_code = None
    size = 0

    try:
        parts = result.stdout.strip().split()

        if len(parts) >= 2:
            http_code = int(parts[-2])
            size = int(float(parts[-1]))

    except Exception:
        pass

    # Google generate_204 legitimately has
    # zero response body, so HTTP success itself
    # is accepted when minimum_bytes == 0.
    http_ok = (
        http_code is not None
        and 200 <= http_code < 400
    )

    byte_ok = (
        size >= target.minimum_bytes
    )

    success = (
        result.returncode == 0
        and http_ok
        and byte_ok
    )

    error = None

    if not success:
        if result.returncode != 0:
            error = (
                "curl_exit_"
                + str(result.returncode)
            )
        elif not http_ok:
            error = "http_failure"
        elif not byte_ok:
            error = "insufficient_bytes"
        else:
            error = "download_failed"

    return DownloadMeasurement(
        provider=target.provider,
        success=success,
        bytes_transferred=size,
        duration_ms=duration,
        http_code=http_code,
        error=error,
    )
