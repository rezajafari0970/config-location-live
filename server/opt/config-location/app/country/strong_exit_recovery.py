from __future__ import annotations

import ipaddress
import subprocess
import time

from collections import Counter
from dataclasses import dataclass


@dataclass(frozen=True)
class StrongExitResult:

    state: str

    exit_ip: str | None

    agreed: int

    successful: int

    attempts: int

    reason: str

    evidence: tuple[
        tuple[str,str],
        ...
    ]


ENDPOINTS=(
    "https://api.ipify.org",
    "https://icanhazip.com",
    "https://ifconfig.me/ip",
    "https://checkip.amazonaws.com",
    "https://ident.me",
)


def normalize_ip(
    value: str,
) -> str | None:

    value=value.strip()

    if not value:
        return None

    value=value.splitlines()[0].strip()

    try:
        ip=ipaddress.ip_address(
            value
        )
    except Exception:
        return None

    if not ip.is_global:
        return None

    return ip.compressed


def probe(
    *,
    proxy_url: str,
    url: str,
    timeout: float=8.0,
) -> str | None:

    cmd=[
        "curl",
        "-fsS",
        "--connect-timeout",
        "4",
        "--max-time",
        str(timeout),
        "--proxy",
        proxy_url,
        url,
    ]

    try:

        p=subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout+2,
        )

    except Exception:
        return None


    if p.returncode!=0:
        return None

    return normalize_ip(
        p.stdout
    )


def observe_strong_exit(
    *,
    proxy_url: str,
    rounds: int=3,
) -> StrongExitResult:

    values=[]

    evidence=[]


    for round_no in range(
        rounds
    ):

        for url in ENDPOINTS:

            ip=probe(
                proxy_url=proxy_url,
                url=url,
            )

            if ip:

                values.append(
                    ip
                )

                evidence.append(
                    (
                        url,
                        ip,
                    )
                )


        if round_no+1 < rounds:
            time.sleep(0.7)


    if not values:

        return StrongExitResult(
            state="unknown",
            exit_ip=None,
            agreed=0,
            successful=0,
            attempts=(
                rounds
                * len(ENDPOINTS)
            ),
            reason=
                "strong_exit_no_response",
            evidence=tuple(
                evidence
            ),
        )


    counts=Counter(
        values
    )

    ip,agreed=(
        counts.most_common(
            1
        )[0]
    )


    # Strong majority rather than simple 2-vote
    # consensus.
    ratio=agreed/len(values)


    if (
        agreed>=3
        and ratio>=0.60
    ):

        return StrongExitResult(
            state="confirmed",
            exit_ip=ip,
            agreed=agreed,
            successful=
                len(values),
            attempts=(
                rounds
                * len(ENDPOINTS)
            ),
            reason=
                "strong_exit_consensus",
            evidence=tuple(
                evidence
            ),
        )


    return StrongExitResult(
        state="unstable_exit",
        exit_ip=None,
        agreed=agreed,
        successful=
            len(values),
        attempts=(
            rounds
            * len(ENDPOINTS)
        ),
        reason=
            "strong_exit_no_majority",
        evidence=tuple(
            evidence
        ),
    )
