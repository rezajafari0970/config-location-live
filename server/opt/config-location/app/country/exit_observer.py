from __future__ import annotations

import ipaddress
import subprocess
import time

from concurrent.futures import (
    ThreadPoolExecutor,
    as_completed,
)

from collections import Counter
from dataclasses import dataclass
from typing import Iterable


@dataclass(frozen=True)
class ExitProbe:
    provider: str
    url: str
    success: bool
    ip: str | None
    duration_ms: int
    error: str | None = None


@dataclass(frozen=True)
class ExitObservation:
    state: str
    exit_ip: str | None
    agreed: int
    successful: int
    total: int
    probes: tuple[ExitProbe, ...]
    reason: str


DEFAULT_ENDPOINTS = (
    (
        "ipify",
        "https://api.ipify.org",
    ),
    (
        "icanhazip",
        "https://icanhazip.com",
    ),
    (
        "ifconfig_me",
        "https://ifconfig.me/ip",
    ),
)


def normalize_ip(
    value: str,
) -> str | None:

    value = (
        value
        .strip()
        .splitlines()[0]
        .strip()
        if value.strip()
        else ""
    )

    if not value:
        return None

    try:
        ip = ipaddress.ip_address(
            value
        )
    except ValueError:
        return None

    if not ip.is_global:
        return None

    return ip.compressed


def probe_exit_ip(
    *,
    provider: str,
    url: str,
    proxy_url: str | None,
    timeout: float = 8.0,
) -> ExitProbe:

    cmd = [
        "curl",
        "-4",
        "-fsS",
        "--connect-timeout",
        str(
            min(
                timeout,
                5.0,
            )
        ),
        "--max-time",
        str(timeout),
    ]

    if proxy_url:
        cmd += [
            "--proxy",
            proxy_url,
        ]

    cmd.append(url)

    started = time.monotonic()

    try:
        result = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout + 2.0,
        )

        duration_ms = int(
            (
                time.monotonic()
                - started
            )
            * 1000
        )

        if result.returncode != 0:
            return ExitProbe(
                provider=provider,
                url=url,
                success=False,
                ip=None,
                duration_ms=duration_ms,
                error=(
                    result.stderr.strip()
                    or
                    f"curl_exit_{result.returncode}"
                )[:500],
            )

        ip = normalize_ip(
            result.stdout
        )

        if ip is None:
            return ExitProbe(
                provider=provider,
                url=url,
                success=False,
                ip=None,
                duration_ms=duration_ms,
                error="invalid_ip_response",
            )

        return ExitProbe(
            provider=provider,
            url=url,
            success=True,
            ip=ip,
            duration_ms=duration_ms,
        )

    except subprocess.TimeoutExpired:

        duration_ms = int(
            (
                time.monotonic()
                - started
            )
            * 1000
        )

        return ExitProbe(
            provider=provider,
            url=url,
            success=False,
            ip=None,
            duration_ms=duration_ms,
            error="timeout",
        )


def observe_exit_ip(
    *,
    proxy_url: str | None,
    endpoints: Iterable[
        tuple[str, str]
    ] = DEFAULT_ENDPOINTS,
    timeout: float = 8.0,
    minimum_agreement: int = 2,
) -> ExitObservation:
    """
    FIX22K3_PARALLEL_EXIT_OBSERVER

    Run independent exit-IP providers concurrently.

    Semantics preserved:
      - only globally-routable IPs are accepted
      - minimum_agreement remains authoritative
      - disagreement never becomes confirmed

    Optimization:
      - return immediately once enough providers
        agree on the same exit IP.
    """

    endpoint_list=tuple(endpoints)

    if not endpoint_list:

        return ExitObservation(
            state="error",
            exit_ip=None,
            agreed=0,
            successful=0,
            total=0,
            probes=(),
            reason="no_exit_endpoints",
        )


    workers=min(
        len(endpoint_list),
        4,
    )


    executor=ThreadPoolExecutor(
        max_workers=workers,
        thread_name_prefix=
            "country-exit",
    )


    futures={
        executor.submit(
            probe_exit_ip,
            provider=provider,
            url=url,
            proxy_url=proxy_url,
            timeout=timeout,
        ):(
            provider,
            url,
        )
        for provider,url
        in endpoint_list
    }


    completed=[]
    counts=Counter()


    try:

        for future in as_completed(
            futures
        ):

            try:
                probe=future.result()

            except Exception as exc:

                provider,url=(
                    futures[future]
                )

                probe=ExitProbe(
                    provider=provider,
                    url=url,
                    success=False,
                    ip=None,
                    duration_ms=0,
                    error=(
                        f"{type(exc).__name__}: "
                        f"{exc}"
                    )[:500],
                )


            completed.append(probe)


            if (
                probe.success
                and probe.ip
            ):

                counts[
                    probe.ip
                ]+=1


                agreed=counts[
                    probe.ip
                ]


                if (
                    agreed
                    >= minimum_agreement
                ):

                    # Do not wait for slower providers.
                    # Futures that have not started are
                    # cancelled; running curl processes
                    # finish under their own timeout.
                    for f in futures:

                        if not f.done():
                            f.cancel()


                    return ExitObservation(
                        state="confirmed",
                        exit_ip=probe.ip,
                        agreed=agreed,
                        successful=sum(
                            1
                            for p in completed
                            if (
                                p.success
                                and p.ip
                            )
                        ),
                        total=len(
                            endpoint_list
                        ),
                        probes=tuple(
                            completed
                        ),
                        reason=(
                            "exit_ip_consensus_"
                            "parallel_early_exit"
                        ),
                    )


        successful=[
            p
            for p in completed
            if (
                p.success
                and p.ip
            )
        ]


        if not successful:

            return ExitObservation(
                state="error",
                exit_ip=None,
                agreed=0,
                successful=0,
                total=len(
                    endpoint_list
                ),
                probes=tuple(
                    completed
                ),
                reason=(
                    "no_exit_probe_succeeded"
                ),
            )


        counts=Counter(
            p.ip
            for p in successful
        )

        exit_ip,agreed=(
            counts.most_common(1)[0]
        )


        if (
            agreed
            >= minimum_agreement
        ):

            return ExitObservation(
                state="confirmed",
                exit_ip=exit_ip,
                agreed=agreed,
                successful=len(
                    successful
                ),
                total=len(
                    endpoint_list
                ),
                probes=tuple(
                    completed
                ),
                reason=(
                    "exit_ip_consensus_parallel"
                ),
            )


        return ExitObservation(
            state="unstable_exit",
            exit_ip=None,
            agreed=agreed,
            successful=len(
                successful
            ),
            total=len(
                endpoint_list
            ),
            probes=tuple(
                completed
            ),
            reason=(
                "exit_ip_disagreement"
            ),
        )


    finally:

        executor.shutdown(
            wait=False,
            cancel_futures=True,
        )
