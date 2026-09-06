from __future__ import annotations

from pathlib import Path

from .continuous_adaptive_runner import (
    run_continuous_adaptive_test,
)

from .scheduler import (
    SchedulerLock,
)


QUEUE = Path(
    "/var/lib/config-location/"
    "health-adaptive/queue-state.json"
)

METRICS = Path(
    "/var/lib/config-location/"
    "health-adaptive/metrics.json"
)

REPORT = Path(
    "/var/lib/config-location/"
    "health-adaptive/last-run.json"
)

RESULTS = Path(
    "/var/lib/config-location/"
    "health-results"
)

LOCK = Path(
    "/run/config-location-health-adaptive.lock"
)


def run_production_adaptive_once(
    *,
    max_jobs: int = 300,
    effective_runtime: dict | None = None,
    cancel_check=None,
):

    with SchedulerLock(
        LOCK
    ):

        return (
            run_continuous_adaptive_test(
                queue_path=QUEUE,

                metrics_path=METRICS,

                report_path=REPORT,

                result_root=RESULTS,

                max_test_jobs=max_jobs,

                monitor_interval=5.0,

                reconcile_interval=5.0,

                effective_runtime=
                    effective_runtime,

                cancel_check=
                    cancel_check,
            )
        )
