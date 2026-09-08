from __future__ import annotations

import fcntl
import json
import os
import signal
import time
import traceback

from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.settings.engine import get_settings
from app.core.config_store import delete_config, list_configs

from app.health.retest import (
    build_privileged_retest_plan,
)

from app.health.core.production_scheduler import (
    discover_jobs,
)

from app.health.core.batch import (
    BatchRunner,
)

from app.health.storage.json_store import (
    JsonHealthResultStore,
)


CONFIG_ROOT = Path(
    "/var/lib/config-location/configs"
)

HEALTH_ROOT = Path(
    "/var/lib/config-location/health-results"
)

STATE_ROOT = Path(
    "/var/lib/config-location/retest"
)

STATUS = STATE_ROOT / "status.json"

LOCK_PATH = Path(
    "/run/config-location-retest/worker.lock"
)


MIN_WORKERS = 1
MAX_WORKERS = 3

MIN_BATCH = 2
MAX_BATCH = 9

LOW_IDLE = 5
NORMAL_IDLE = 15
HIGH_IDLE = 30


_shutdown = False


def now() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def handle_signal(
    signum,
    frame,
) -> None:

    global _shutdown
    _shutdown = True


signal.signal(
    signal.SIGTERM,
    handle_signal,
)

signal.signal(
    signal.SIGINT,
    handle_signal,
)


def atomic_json(
    path: Path,
    payload: dict[str, Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    tmp = path.with_suffix(
        ".tmp"
    )

    tmp.write_text(
        json.dumps(
            payload,
            ensure_ascii=False,
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )

    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def read_status() -> dict[str, Any]:

    try:
        return json.loads(
            STATUS.read_text(
                encoding="utf-8"
            )
        )
    except Exception:
        return {}


def write_status(
    **values: Any,
) -> None:

    data = read_status()

    data.update(values)

    data["updated_at"] = now()
    data["pid"] = os.getpid()

    atomic_json(
        STATUS,
        data,
    )


def resource_snapshot() -> dict[str, Any]:

    cpu_count = max(
        os.cpu_count() or 1,
        1,
    )

    try:
        load1, load5, load15 = os.getloadavg()
    except OSError:
        load1 = load5 = load15 = 0.0

    load_ratio = (
        load1 / cpu_count
    )

    total_kb = 0
    avail_kb = 0

    try:
        for line in Path(
            "/proc/meminfo"
        ).read_text().splitlines():

            if line.startswith(
                "MemTotal:"
            ):
                total_kb = int(
                    line.split()[1]
                )

            elif line.startswith(
                "MemAvailable:"
            ):
                avail_kb = int(
                    line.split()[1]
                )
    except Exception:
        pass

    mem_available_pct = (
        (avail_kb / total_kb) * 100
        if total_kb
        else 100.0
    )

    return {
        "cpu_count":
            cpu_count,

        "load1":
            round(load1, 3),

        "load5":
            round(load5, 3),

        "load15":
            round(load15, 3),

        "load_ratio":
            round(load_ratio, 3),

        "mem_available_pct":
            round(
                mem_available_pct,
                2,
            ),
    }



def resource_guardian_settings() -> dict[str, Any]:
    """
    Canonical Resource Guardian binding.

    Source of truth:
        settings["resources"]

    Canonical keys:
        cpu_warning_percent
        cpu_critical_percent
        ram_warning_percent
        ram_critical_percent
        disk_warning_percent
        disk_critical_percent
    """

    settings = get_settings()

    resources = settings.get(
        "resources",
        {},
    )

    if not isinstance(
        resources,
        dict,
    ):
        resources = {}


    def read(
        key: str,
        default: float,
    ) -> float:

        value = resources.get(
            key,
            default,
        )

        try:
            return float(value)
        except (
            TypeError,
            ValueError,
        ):
            return float(default)


    return {
        "cpu_warning_pct":
            read(
                "cpu_warning_percent",
                75.0,
            ),

        "cpu_critical_pct":
            read(
                "cpu_critical_percent",
                94.0,
            ),

        "ram_warning_pct":
            read(
                "ram_warning_percent",
                80.0,
            ),

        "ram_critical_pct":
            read(
                "ram_critical_percent",
                92.0,
            ),

        "disk_warning_pct":
            read(
                "disk_warning_percent",
                75.0,
            ),

        "disk_critical_pct":
            read(
                "disk_critical_percent",
                90.0,
            ),

        "sources": {
            "cpu_warning_pct":
                "resources.cpu_warning_percent",

            "cpu_critical_pct":
                "resources.cpu_critical_percent",

            "ram_warning_pct":
                "resources.ram_warning_percent",

            "ram_critical_pct":
                "resources.ram_critical_percent",

            "disk_warning_pct":
                "resources.disk_warning_percent",

            "disk_critical_pct":
                "resources.disk_critical_percent",
        },
    }


def adaptive_policy(
    resource: dict[str, Any],
    due_total: int,
) -> dict[str, Any]:

    guardian = (
        resource_guardian_settings()
    )

    # Linux load ratio is used as our CPU pressure
    # signal. Convert it to a percentage so it can
    # obey the Central Resource Guardian thresholds.
    cpu_pressure_pct = min(
        max(
            float(
                resource["load_ratio"]
            ) * 100.0,
            0.0,
        ),
        1000.0,
    )

    mem_available_pct = float(
        resource[
            "mem_available_pct"
        ]
    )

    ram_used_pct = max(
        0.0,
        100.0 - mem_available_pct,
    )

    cpu_warning = guardian[
        "cpu_warning_pct"
    ]

    cpu_critical = guardian[
        "cpu_critical_pct"
    ]

    ram_warning = guardian[
        "ram_warning_pct"
    ]

    ram_critical = guardian[
        "ram_critical_pct"
    ]


    if (
        cpu_pressure_pct >= cpu_critical
        or ram_used_pct >= ram_critical
    ):
        return {
            "workers": 1,
            "batch": 2,
            "idle": 30,
            "level": "critical",
            "reason": (
                "resource_guardian_critical"
            ),
            "guardian": guardian,
            "cpu_pressure_pct": round(
                cpu_pressure_pct,
                2,
            ),
            "ram_used_pct": round(
                ram_used_pct,
                2,
            ),
        }


    if (
        cpu_pressure_pct >= cpu_warning
        or ram_used_pct >= ram_warning
    ):
        return {
            "workers": 1,
            "batch": 3,
            "idle": 15,
            "level": "warning",
            "reason": (
                "resource_guardian_warning"
            ),
            "guardian": guardian,
            "cpu_pressure_pct": round(
                cpu_pressure_pct,
                2,
            ),
            "ram_used_pct": round(
                ram_used_pct,
                2,
            ),
        }


    if due_total >= 200:
        workers=3
        batch=9
        reason="healthy_resources_large_backlog"

    elif due_total >= 50:
        workers=2
        batch=6
        reason="healthy_resources_medium_backlog"

    else:
        workers=1
        batch=3
        reason="healthy_resources_small_backlog"


    return {
        "workers": workers,
        "batch": batch,
        "idle": (
            5
            if due_total >= 50
            else 15
        ),
        "level": "normal",
        "reason": reason,
        "guardian": guardian,
        "cpu_pressure_pct": round(
            cpu_pressure_pct,
            2,
        ),
        "ram_used_pct": round(
            ram_used_pct,
            2,
        ),
    }


def sleep_interruptible(
    seconds: int,
) -> None:

    for _ in range(
        max(
            int(seconds),
            0,
        )
    ):
        if _shutdown:
            return

        time.sleep(1)


def main() -> int:

    STATE_ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )

    LOCK_PATH.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd = os.open(
        LOCK_PATH,
        os.O_CREAT | os.O_RDWR,
        0o600,
    )

    try:
        fcntl.flock(
            fd,
            fcntl.LOCK_EX
            | fcntl.LOCK_NB,
        )
    except BlockingIOError:

        write_status(
            state="blocked",
            reason="already_running",
        )

        return 2


    store = JsonHealthResultStore(
        HEALTH_ROOT
    )


    previous = read_status()

    # Remove stale lifecycle fields left by
    # an earlier worker process.
    for stale_key in (
        "stopped_at",
        "current_config_id",
        "current_config_type",
        "current_test_started_at",
    ):
        previous.pop(
            stale_key,
            None,
        )

    atomic_json(
        STATUS,
        previous,
    )

    cycle = int(
        previous.get(
            "cycle",
            0,
        )
        or 0
    )

    total_tests = int(
        previous.get(
            "total_tests",
            0,
        )
        or 0
    )

    total_healthy = int(
        previous.get(
            "total_healthy",
            0,
        )
        or 0
    )

    total_unhealthy = int(
        previous.get(
            "total_unhealthy",
            0,
        )
        or 0
    )

    total_errors = int(
        previous.get(
            "total_errors",
            0,
        )
        or 0
    )

    total_runtime_seconds = float(
        previous.get(
            "total_test_runtime_seconds",
            0,
        )
        or 0
    )


    write_status(
        component="retest-worker",
        mode="adaptive",
        state="starting",
        min_workers=MIN_WORKERS,
        max_workers=MAX_WORKERS,
        min_batch=MIN_BATCH,
        max_batch=MAX_BATCH,
    )


    while not _shutdown:

        cycle += 1

        cycle_start = time.time()

        try:

            # LIFECYCLE_ENFORCEMENT_V2
            # Lifetime is measured from immutable first_seen_at.
            settings = get_settings()
            lifetime_cfg = settings.get("config_lifetime", {})
            try:
                max_age_hours = float(lifetime_cfg.get("max_age_hours", 48))
            except (TypeError, ValueError):
                max_age_hours = 48.0

            deleted_expired = 0
            if max_age_hours > 0:
                now_dt = datetime.now(timezone.utc)

                for record in list_configs():
                    first_seen = str(record.get("first_seen_at") or "").strip()
                    if not first_seen:
                        continue

                    try:
                        created_dt = datetime.fromisoformat(
                            first_seen.replace("Z", "+00:00")
                        )
                        if created_dt.tzinfo is None:
                            created_dt = created_dt.replace(tzinfo=timezone.utc)
                    except (TypeError, ValueError):
                        continue

                    age_hours = (
                        now_dt - created_dt.astimezone(timezone.utc)
                    ).total_seconds() / 3600.0

                    if age_hours < max_age_hours:
                        continue

                    outcome = delete_config(
                        str(record["id"]),
                        reason="config_lifetime_expired",
                        actor="retest-worker",
                        metadata={
                            "first_seen_at": first_seen,
                            "age_hours": round(age_hours, 6),
                            "max_age_hours": max_age_hours,
                        },
                    )

                    if outcome.get("deleted"):
                        deleted_expired += 1

            # First look at due count
            # with a small plan.
            preview = (
                build_privileged_retest_plan(
                    limit=1
                )
            )

            resource = (
                resource_snapshot()
            )

            policy = adaptive_policy(
                resource,
                int(
                    preview[
                        "due_total"
                    ]
                ),
            )

            workers = max(
                MIN_WORKERS,
                min(
                    int(
                        policy[
                            "workers"
                        ]
                    ),
                    MAX_WORKERS,
                ),
            )

            batch_size = max(
                MIN_BATCH,
                min(
                    int(
                        policy[
                            "batch"
                        ]
                    ),
                    MAX_BATCH,
                ),
            )

            idle_seconds = int(
                policy["idle"]
            )


            plan = (
                build_privileged_retest_plan(
                    limit=batch_size
                )
            )


            jobs = discover_jobs(
                CONFIG_ROOT
            )

            job_map = {
                job.config_id:
                    job
                for job
                in jobs
            }


            selected = []

            for candidate in (
                plan["candidates"]
            ):

                job = job_map.get(
                    candidate[
                        "config_id"
                    ]
                )

                if job is not None:
                    selected.append(
                        job
                    )


            write_status(
                state="running",
                mode="adaptive",
                cycle=cycle,
                cycle_started_at=now(),

                retest_minutes=(
                    plan[
                        "retest_minutes"
                    ]
                ),

                scanned_records=(
                    plan[
                        "scanned_records"
                    ]
                ),

                real_healthy=(
                    plan[
                        "real_healthy"
                    ]
                ),

                due_total=(
                    plan[
                        "due_total"
                    ]
                ),

                selected_count=(
                    len(selected)
                ),

                adaptive_workers=(
                    workers
                ),

                adaptive_batch=(
                    batch_size
                ),

                adaptive_idle_seconds=(
                    idle_seconds
                ),

                resource=resource,

                resource_guardian=(
                    policy.get(
                        "guardian",
                        {},
                    )
                ),

                resource_level=(
                    policy.get(
                        "level"
                    )
                ),

                adaptive_reason=(
                    policy.get(
                        "reason"
                    )
                ),

                cpu_pressure_pct=(
                    policy.get(
                        "cpu_pressure_pct"
                    )
                ),

                ram_used_pct=(
                    policy.get(
                        "ram_used_pct"
                    )
                ),

                deleted_expired=deleted_expired,
                max_age_hours=max_age_hours,
                last_error=None,
            )


            if not selected:

                write_status(
                    state="idle",
                    cycle_finished_at=now(),
                    selected_count=0,
                )

                sleep_interruptible(
                    idle_seconds
                )

                continue


            runner = BatchRunner(
                max_workers=workers,
                result_store=store,
            )


            batch_started = time.time()


            results, summary = (
                runner.run(
                    selected
                )
            )


            batch_elapsed = (
                time.time()
                - batch_started
            )


            cycle_completed = len(
                results
            )


            cycle_healthy = sum(
                1
                for result
                in results
                if result.healthy
            )

            cycle_unhealthy = (
                cycle_completed
                - cycle_healthy
            )


            total_tests += (
                cycle_completed
            )

            total_healthy += (
                cycle_healthy
            )

            total_unhealthy += (
                cycle_unhealthy
            )

            total_runtime_seconds += (
                batch_elapsed
            )


            avg_test_seconds = (
                total_runtime_seconds
                / total_tests
                if total_tests
                else 0.0
            )


            throughput_hour = (
                (
                    cycle_completed
                    / batch_elapsed
                )
                * 3600
                if batch_elapsed > 0
                else 0.0
            )


            healthy_rate = (
                (
                    total_healthy
                    / total_tests
                )
                * 100
                if total_tests
                else 0.0
            )


            # LIFECYCLE_ENFORCEMENT_V1
            # Active Store contains healthy/live configs only.
            # Failed retest => immediate removal.
            deleted_unhealthy = 0

            for result in results:
                if result.healthy:
                    continue

                outcome = delete_config(
                    result.config_id,
                    reason="health_retest_failed",
                    actor="retest-worker",
                    metadata={
                        "error_code": result.error_code,
                        "finished_at": result.finished_at,
                    },
                )
                if outcome.get("deleted"):
                    deleted_unhealthy += 1

            cycle_results = []

            for result in results:
                cycle_results.append(
                    {
                        "config_id":
                            result.config_id,

                        "config_type":
                            result.config_type,

                        "state":
                            result.state.value,

                        "healthy":
                            result.healthy,

                        "xray_started":
                            result.xray_started,

                        "download_verified":
                            result.download_verified,

                        "upload_verified":
                            result.upload_verified,

                        "error_code":
                            result.error_code,

                        "finished_at":
                            result.finished_at,
                    }
                )


            write_status(
                state="idle",

                cycle_finished_at=now(),

                cycle_elapsed_seconds=round(
                    time.time()
                    - cycle_start,
                    3,
                ),

                batch_elapsed_seconds=round(
                    batch_elapsed,
                    3,
                ),

                cycle_completed=(
                    cycle_completed
                ),

                cycle_healthy=(
                    cycle_healthy
                ),

                cycle_unhealthy=(
                    cycle_unhealthy
                ),

                deleted_unhealthy=(
                    deleted_unhealthy
                ),

                cycle_results=(
                    cycle_results
                ),

                total_tests=(
                    total_tests
                ),

                total_healthy=(
                    total_healthy
                ),

                total_unhealthy=(
                    total_unhealthy
                ),

                total_errors=(
                    total_errors
                ),

                total_test_runtime_seconds=round(
                    total_runtime_seconds,
                    3,
                ),

                average_test_seconds=round(
                    avg_test_seconds,
                    3,
                ),

                current_throughput_per_hour=round(
                    throughput_hour,
                    2,
                ),

                overall_healthy_rate_pct=round(
                    healthy_rate,
                    2,
                ),
            )


            sleep_interruptible(
                idle_seconds
            )


        except Exception as exc:

            total_errors += 1

            write_status(
                state="cycle_error",
                total_errors=total_errors,

                last_error={
                    "exception":
                        repr(exc),

                    "traceback":
                        traceback.format_exc()[
                            -5000:
                        ],
                },
            )

            sleep_interruptible(
                HIGH_IDLE
            )


    write_status(
        state="stopped",
        stopped_at=now(),
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
