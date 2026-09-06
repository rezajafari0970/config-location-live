from __future__ import annotations

import subprocess
import tempfile
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
class UploadTarget:
    provider: str
    url: str
    method: str = "POST"
    minimum_bytes: int = 32768


@dataclass(frozen=True)
class UploadMeasurement:
    provider: str
    success: bool
    bytes_transferred: int
    duration_ms: int
    http_code: int | None
    error: str | None


# Independent providers. A provider failure does
# not fail the whole upload test. Health policy
# later requires >= 1 successful real upload.
DEFAULT_TARGETS = (
    UploadTarget(
        provider="cloudflare",
        url="https://speed.cloudflare.com/__up",
        minimum_bytes=32768,
    ),

    UploadTarget(
        provider="google",
        url="https://www.google.com/",
        minimum_bytes=32768,
    ),

    UploadTarget(
        provider="microsoft",
        url="https://www.microsoft.com/",
        minimum_bytes=32768,
    ),
)


def _payload(
    directory: Path,
    size: int,
) -> Path:

    path = directory / "upload.bin"

    # Random payload prevents accidental
    # compression/dedup assumptions.
    with path.open("wb") as fh:
        remaining = size

        while remaining:
            chunk_size = min(
                remaining,
                65536,
            )

            fh.write(
                __import__("os").urandom(
                    chunk_size
                )
            )

            remaining -= chunk_size

    return path


def run_upload(
    *,
    target: UploadTarget,
    proxy_url: str,
    timeout_seconds: float = 15.0,
    payload_bytes: int = 65536,
    cancel_check=None,
) -> UploadMeasurement:

    start = time.monotonic()

    with tempfile.TemporaryDirectory(
        prefix="health-upload-"
    ) as td:

        payload = _payload(
            Path(td),
            payload_bytes,
        )

        command = [
            "curl",
            "--silent",
            "--show-error",
            "--location",
            "--proxy",
            proxy_url,
            "--connect-timeout",
            str(
                min(
                    7.0,
                    timeout_seconds,
                )
            ),
            "--max-time",
            str(timeout_seconds),
            "--request",
            target.method,
            "--header",
            "Content-Type: application/octet-stream",
            "--data-binary",
            f"@{payload}",
            "--output",
            "/dev/null",
            "--write-out",
            "%{http_code} %{size_upload}",
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

            return UploadMeasurement(
                provider=target.provider,
                success=False,
                bytes_transferred=0,
                duration_ms=int(
                    (
                        time.monotonic()
                        - start
                    )
                    * 1000
                ),
                http_code=None,
                error="process_timeout",
            )

    duration = int(
        (
            time.monotonic()
            - start
        )
        * 1000
    )

    http_code = None
    uploaded = 0

    try:
        parts = (
            result.stdout
            .strip()
            .split()
        )

        if len(parts) >= 2:
            http_code = int(
                parts[-2]
            )

            uploaded = int(
                float(parts[-1])
            )

    except Exception:
        pass

    # For upload verification the important
    # evidence is:
    #
    # 1. curl completed the HTTP exchange
    # 2. payload bytes were actually transmitted
    #
    # Some public endpoints reject POST after
    # receiving it (403/404/405). That proves
    # transport, but we deliberately require
    # an actual HTTP response and full payload.
    http_received = (
        http_code is not None
        and http_code > 0
    )

    byte_ok = (
        uploaded
        >= target.minimum_bytes
        and uploaded >= payload_bytes
    )

    success = (
        result.returncode == 0
        and http_received
        and byte_ok
    )

    error = None

    if not success:

        if result.returncode != 0:
            error = (
                "curl_exit_"
                + str(result.returncode)
            )

        elif not http_received:
            error = "no_http_response"

        elif not byte_ok:
            error = "insufficient_upload"

        else:
            error = "upload_failed"

    return UploadMeasurement(
        provider=target.provider,
        success=success,
        bytes_transferred=uploaded,
        duration_ms=duration,
        http_code=http_code,
        error=error,
    )
