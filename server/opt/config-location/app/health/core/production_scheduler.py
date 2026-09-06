from __future__ import annotations

import json
import os
import time

from collections import Counter
from concurrent.futures import (
    ThreadPoolExecutor,
    as_completed,
)

from dataclasses import dataclass
from pathlib import Path

from .batch import BatchJob
from .models import (
    HealthResult,
    HealthState,
)
from .retry import (
    run_health_with_retry,
)
from .scheduler import (
    SchedulerBusy,
    SchedulerLock,
    mix_jobs_by_type,
)
from ..settings import (
    HealthSettings,
    load_health_settings,
)
from ..storage.json_store import (
    JsonHealthResultStore,
)


ORDERING_VERSION = (
    "type-interleaved-v1"
)

SUPPORTED_TYPES = {
    "vless",
    "vmess",
    "ss",
    "trojan",
    "socks",
    "wireguard",
    "json_xray",

    "hysteria",
    "hysteria2",
    "hy",
    "hy2",
    "tuic",
    "anytls",
    "naive",
    "juicity",
}


@dataclass(frozen=True)
class ProductionRunSummary:
    discovered: int
    selected: int
    completed: int

    healthy: int
    unhealthy: int
    error: int

    retries_used: int

    cursor_before: int
    cursor_after: int

    duration_ms: int

    max_workers: int
    batch_size: int


def _atomic_json(
    path: Path,
    value: dict,
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    tmp = path.with_name(
        "." + path.name + ".tmp"
    )

    tmp.write_text(
        json.dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    tmp.chmod(0o600)

    os.replace(
        tmp,
        path,
    )


def load_state(
    path: Path,
) -> dict:

    if not path.exists():
        return {
            "ordering_version":
                ORDERING_VERSION,

            "cursor":
                0,
        }

    try:

        obj = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

    except Exception:

        return {
            "ordering_version":
                ORDERING_VERSION,

            "cursor":
                0,
        }


    if (
        obj.get(
            "ordering_version"
        )
        != ORDERING_VERSION
    ):

        # Previous scheduler used another
        # ordering. Reset cursor safely instead
        # of applying an old cursor to a new
        # sequence.
        return {
            "ordering_version":
                ORDERING_VERSION,

            "cursor":
                0,

            "migration":
                "ordering_reset",
        }


    try:
        cursor = max(
            0,
            int(
                obj.get(
                    "cursor",
                    0,
                )
            ),
        )
    except Exception:
        cursor = 0


    return {
        "ordering_version":
            ORDERING_VERSION,

        "cursor":
            cursor,
    }


def discover_jobs(
    store_root: Path,
) -> list[BatchJob]:

    jobs = []

    seen = set()


    for path in store_root.glob(
        "*.json"
    ):

        try:

            record = json.loads(
                path.read_text(
                    encoding="utf-8"
                )
            )

        except Exception:
            continue


        if not isinstance(
            record,
            dict,
        ):
            continue


        config_id = record.get(
            "id"
        )

        kind = str(
            record.get(
                "type",
                "",
            )
        ).strip().lower()

        raw = record.get(
            "raw"
        )


        if (
            not config_id
            or kind not in SUPPORTED_TYPES
            or not isinstance(
                raw,
                str,
            )
        ):
            continue


        config_id = str(
            config_id
        )


        if config_id in seen:
            continue


        seen.add(
            config_id
        )


        jobs.append(
            BatchJob(
                config_id=config_id,
                config_type=kind,
                source=raw,
            )
        )


    return mix_jobs_by_type(
        jobs
    )


def select_jobs(
    jobs: list[BatchJob],
    *,
    cursor: int,
    batch_size: int,
) -> tuple[
    list[BatchJob],
    int,
]:

    if not jobs:
        return [], 0


    cursor = (
        cursor
        % len(jobs)
    )


    count = min(
        batch_size,
        len(jobs),
    )


    selected = []

    index = cursor


    for _ in range(
        count
    ):

        selected.append(
            jobs[index]
        )

        index = (
            index + 1
        ) % len(jobs)


    return (
        selected,
        index,
    )


def execute_one(
    job: BatchJob,
    *,
    settings: HealthSettings,
    result_store: JsonHealthResultStore,
):

    outcome = run_health_with_retry(
        config_id=job.config_id,
        config_type=job.config_type,
        source=job.source,

        startup_timeout=(
            settings.startup_timeout
        ),

        download_timeout=(
            settings.download_timeout
        ),

        upload_timeout=(
            settings.upload_timeout
        ),

        upload_payload_bytes=(
            settings.upload_payload_bytes
        ),

        retry_count=(
            settings.runtime_retry_count
        ),
    )


    result_store.save(
        outcome.result
    )


    return outcome


def run_production_scheduler_once(
    *,
    store_root: Path = Path(
        "/var/lib/config-location/configs"
    ),

    result_root: Path = Path(
        "/var/lib/config-location/"
        "health-results"
    ),

    state_path: Path = Path(
        "/var/lib/config-location/"
        "health-scheduler/state.json"
    ),

    lock_path: Path = Path(
        "/run/config-location-health.lock"
    ),

) -> ProductionRunSummary:

    settings = (
        load_health_settings()
    )


    started = time.monotonic()


    with SchedulerLock(
        lock_path
    ):

        jobs = discover_jobs(
            store_root
        )


        state = load_state(
            state_path
        )


        cursor_before = int(
            state.get(
                "cursor",
                0,
            )
        )


        selected, cursor_after = (
            select_jobs(
                jobs,
                cursor=cursor_before,
                batch_size=(
                    settings.batch_size
                ),
            )
        )


        result_store = (
            JsonHealthResultStore(
                result_root
            )
        )


        outcomes = []


        with ThreadPoolExecutor(
            max_workers=(
                settings.max_workers
            ),

            thread_name_prefix=(
                "production-health"
            ),
        ) as pool:

            futures = {
                pool.submit(
                    execute_one,
                    job,
                    settings=settings,
                    result_store=(
                        result_store
                    ),
                ): job

                for job in selected
            }


            for future in as_completed(
                futures
            ):

                job = futures[
                    future
                ]

                try:

                    outcome = (
                        future.result()
                    )

                except Exception as exc:

                    # A batch-level exception must
                    # still become an explicit result.
                    result = HealthResult(
                        job_id=(
                            "production-exception-"
                            + job.config_id
                            + "-"
                            + str(
                                time.time_ns()
                            )
                        ),

                        config_id=(
                            job.config_id
                        ),

                        config_type=(
                            job.config_type
                        ),

                        state=(
                            HealthState.ERROR
                        ),

                        error_code=(
                            type(
                                exc
                            ).__name__
                        ),

                        error_message=str(
                            exc
                        ),
                    )


                    result_store.save(
                        result
                    )


                    class SyntheticOutcome:
                        pass


                    outcome = (
                        SyntheticOutcome()
                    )

                    outcome.result = result
                    outcome.retries_used = 0
                    outcome.retry_reason = None


                outcomes.append(
                    outcome
                )


        # Advance cursor only after every selected
        # job has produced and persisted a result.
        _atomic_json(
            state_path,
            {
                "ordering_version":
                    ORDERING_VERSION,

                "cursor":
                    cursor_after,

                "last_run_completed":
                    True,

                "last_run_selected":
                    len(selected),

                "last_run_timestamp_ns":
                    time.time_ns(),
            },
        )


    results = [
        outcome.result
        for outcome in outcomes
    ]


    healthy = sum(
        result.state
        == HealthState.HEALTHY

        for result
        in results
    )


    unhealthy = sum(
        result.state
        == HealthState.UNHEALTHY

        for result
        in results
    )


    error = sum(
        result.state
        == HealthState.ERROR

        for result
        in results
    )


    retries_used = sum(
        int(
            getattr(
                outcome,
                "retries_used",
                0,
            )
        )

        for outcome
        in outcomes
    )


    duration_ms = int(
        (
            time.monotonic()
            - started
        )
        * 1000
    )


    return ProductionRunSummary(
        discovered=len(jobs),
        selected=len(selected),
        completed=len(results),

        healthy=healthy,
        unhealthy=unhealthy,
        error=error,

        retries_used=retries_used,

        cursor_before=cursor_before,
        cursor_after=cursor_after,

        duration_ms=duration_ms,

        max_workers=(
            settings.max_workers
        ),

        batch_size=(
            settings.batch_size
        ),
    )
