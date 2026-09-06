from __future__ import annotations

import json
import os
import time

from dataclasses import dataclass
from pathlib import Path


SANDBOX_ROOT=Path(
    "/var/lib/config-location/"
    "health-sandboxes"
)

HEALTH_REPORT=Path(
    "/var/lib/config-location/"
    "health-adaptive/last-run.json"
)


@dataclass(frozen=True)
class AdaptiveDecision:

    level: str

    concurrency: int

    max_jobs: int

    interval: int

    load1: float

    cpu_count: int

    load_ratio: float

    health_runtime_count: int

    country_runtime_count: int

    reason: str


def _runtime_counts() -> tuple[int,int]:

    health=0
    country=0

    if not SANDBOX_ROOT.exists():
        return 0,0

    try:

        for p in SANDBOX_ROOT.iterdir():

            if not p.is_dir():
                continue

            if p.name.startswith(
                "country-"
            ):
                country+=1
            else:
                health+=1

    except Exception:
        pass

    return health,country


def _health_backlog_signal() -> bool:

    if not HEALTH_REPORT.exists():
        return False

    try:
        o=json.loads(
            HEALTH_REPORT.read_text()
        )
    except Exception:
        return False

    # Defensive support for multiple report schemas.
    for key in (
        "queue_size",
        "queued",
        "pending",
        "due",
        "eligible_due",
        "backlog",
    ):

        value=o.get(key)

        if isinstance(
            value,
            (int,float),
        ):

            if value >= 50:
                return True

    return False


def decide_adaptive_rate() -> AdaptiveDecision:

    cpu=max(
        1,
        os.cpu_count() or 1,
    )

    try:
        load1=os.getloadavg()[0]
    except Exception:
        load1=0.0

    ratio=load1/cpu

    (
        health_runtime_count,
        country_runtime_count,
    )=_runtime_counts()

    health_backlog=(
        _health_backlog_signal()
    )


    # --------------------------------------------------
    # Health always wins.
    # --------------------------------------------------

    if health_runtime_count >= 6:

        return AdaptiveDecision(
            level="health_priority",
            concurrency=1,
            max_jobs=1,
            interval=30,
            load1=load1,
            cpu_count=cpu,
            load_ratio=ratio,
            health_runtime_count=
                health_runtime_count,
            country_runtime_count=
                country_runtime_count,
            reason="many_health_runtimes",
        )


    if (
        health_backlog
        or ratio >= 0.90
    ):

        return AdaptiveDecision(
            level="pressure",
            concurrency=1,
            max_jobs=2,
            interval=20,
            load1=load1,
            cpu_count=cpu,
            load_ratio=ratio,
            health_runtime_count=
                health_runtime_count,
            country_runtime_count=
                country_runtime_count,
            reason=(
                "health_backlog_or_high_load"
            ),
        )


    if (
        health_runtime_count >= 3
        or ratio >= 0.70
    ):

        return AdaptiveDecision(
            level="busy",
            concurrency=2,
            max_jobs=4,
            interval=12,
            load1=load1,
            cpu_count=cpu,
            load_ratio=ratio,
            health_runtime_count=
                health_runtime_count,
            country_runtime_count=
                country_runtime_count,
            reason="moderate_pressure",
        )


    if (
        health_runtime_count >= 1
        or ratio >= 0.45
    ):

        return AdaptiveDecision(
            level="balanced",
            concurrency=3,
            max_jobs=6,
            interval=8,
            load1=load1,
            cpu_count=cpu,
            load_ratio=ratio,
            health_runtime_count=
                health_runtime_count,
            country_runtime_count=
                country_runtime_count,
            reason="shared_capacity",
        )


    # Server is relaxed: Country may accelerate.
    if ratio < 0.20:

        concurrency=min(
            6,
            max(
                3,
                cpu // 2,
            ),
        )

        return AdaptiveDecision(
            level="fast",
            concurrency=concurrency,
            max_jobs=min(
                18,
                concurrency * 3,
            ),
            interval=4,
            load1=load1,
            cpu_count=cpu,
            load_ratio=ratio,
            health_runtime_count=
                health_runtime_count,
            country_runtime_count=
                country_runtime_count,
            reason="server_idle",
        )


    concurrency=min(
        4,
        max(
            2,
            cpu // 3,
        ),
    )

    return AdaptiveDecision(
        level="normal",
        concurrency=concurrency,
        max_jobs=min(
            12,
            concurrency * 3,
        ),
        interval=6,
        load1=load1,
        cpu_count=cpu,
        load_ratio=ratio,
        health_runtime_count=
            health_runtime_count,
        country_runtime_count=
            country_runtime_count,
        reason="normal_capacity",
    )
