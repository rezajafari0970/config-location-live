from __future__ import annotations

import statistics
import subprocess

from concurrent.futures import (
    ThreadPoolExecutor,
    as_completed,
)

from .adaptive_controller import (
    NetworkSnapshot,
)


TARGETS = (
    (
        "cloudflare",
        "https://speed.cloudflare.com/"
    ),

    (
        "google",
        "https://www.google.com/generate_204"
    ),

    (
        "microsoft",
        "https://www.microsoft.com/"
    ),
)


def _probe(
    url: str,
    timeout: float,
):

    command = [
        "curl",

        "--silent",
        "--show-error",
        "--location",

        "--output",
        "/dev/null",

        "--connect-timeout",
        str(
            min(
                2.0,
                timeout,
            )
        ),

        "--max-time",
        str(timeout),

        "--write-out",
        "%{http_code} "
        "%{time_connect} "
        "%{time_starttransfer}",

        url,
    ]

    try:

        result = subprocess.run(
            command,

            stdin=subprocess.DEVNULL,

            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,

            text=True,

            timeout=timeout + 1,
        )

    except Exception:
        return None

    if result.returncode != 0:
        return None

    parts = (
        result.stdout
        .strip()
        .split()
    )

    if len(parts) < 3:
        return None

    try:

        code = int(
            float(
                parts[0]
            )
        )

        connect = float(
            parts[1]
        )

        first = float(
            parts[2]
        )

    except Exception:
        return None

    if code <= 0:
        return None

    return max(
        connect,
        first,
    ) * 1000.0


def collect_network_parallel(
    *,
    timeout_seconds: float,

    baseline_latency_ms:
        float | None = None,

    degraded_multiplier:
        float = 2.5,

    minimum_success_ratio:
        float = 0.67,

    critical_success_ratio:
        float = 0.34,

) -> NetworkSnapshot:

    latencies = []

    with ThreadPoolExecutor(
        max_workers=len(TARGETS),
        thread_name_prefix="net-guard",
    ) as pool:

        futures = [
            pool.submit(
                _probe,
                url,
                timeout_seconds,
            )
            for _name, url
            in TARGETS
        ]

        for future in as_completed(
            futures
        ):

            value = future.result()

            if value is not None:
                latencies.append(
                    value
                )

    total = len(TARGETS)

    successful = len(
        latencies
    )

    ratio = (
        successful
        / total
    )

    median = (
        statistics.median(
            latencies
        )
        if latencies
        else None
    )

    critical = (
        ratio
        < critical_success_ratio
    )

    degraded = (
        ratio
        < minimum_success_ratio
    )

    if (
        not degraded
        and baseline_latency_ms
        and median is not None
        and baseline_latency_ms > 0
        and median
        > (
            baseline_latency_ms
            * degraded_multiplier
        )
    ):
        degraded = True

    return NetworkSnapshot(
        success_ratio=ratio,

        median_latency_ms=
            median,

        successful=
            successful,

        total=
            total,

        degraded=
            degraded,

        critical=
            critical,
    )
