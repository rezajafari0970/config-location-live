from __future__ import annotations

import json
import os
import time

from collections import deque
from concurrent.futures import (
    FIRST_COMPLETED,
    ThreadPoolExecutor,
    wait,
)

from pathlib import Path

from .adaptive_controller import (
    collect_projects,
    collect_resources,
    decide,
    discover_baseline_ports,
    load_policy,
)

from .adaptive_live_queue import (
    assert_integrity,
    finish_lease,
    lease_next,
    load_state,
    reconcile,
    requeue_lease,
    save_state,
)

from .adaptive_network import (
    collect_network_parallel,
)

from .models import (
    HealthState,
)

from .production_scheduler import (
    discover_jobs,
)

from .retry import (
    run_health_with_retry,
)

from ..storage.json_store import (
    JsonHealthResultStore,
)


def atomic_json(
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


def load_json(
    path: Path,
) -> dict:

    if not path.exists():
        return {}

    try:

        obj = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

        return (
            obj
            if isinstance(
                obj,
                dict,
            )
            else {}
        )

    except Exception:
        return {}


def traffic_failure(
    result,
) -> bool:

    decision = (
        result.metadata.get(
            "health_decision",
            {},
        )
    )

    reason = (
        decision.get(
            "reason"
        )
        or result.error_code
    )

    return reason in {
        "download_failed",
        "upload_failed",
    }


def guard_snapshot(
    *,
    policy: dict,
    baseline_ports: tuple[int, ...],
    baseline_latency_ms: float | None,
):

    net = policy[
        "network_guard"
    ]

    project = policy[
        "project_guard"
    ]

    resources = (
        collect_resources()
    )

    network = (
        collect_network_parallel(
            timeout_seconds=float(
                net[
                    "probe_timeout_seconds"
                ]
            ),

            baseline_latency_ms=
                baseline_latency_ms,

            degraded_multiplier=float(
                net[
                    "latency_degraded_multiplier"
                ]
            ),

            minimum_success_ratio=float(
                net[
                    "minimum_direct_success_ratio"
                ]
            ),

            critical_success_ratio=float(
                net[
                    "critical_direct_success_ratio"
                ]
            ),
        )
    )

    projects = (
        collect_projects(
            services=[
                str(x)
                for x
                in project[
                    "services"
                ]
            ],

            baseline_ports=
                baseline_ports,
        )
    )

    return (
        resources,
        network,
        projects,
    )


def run_continuous_adaptive_test(
    *,
    queue_path: Path,
    metrics_path: Path,
    report_path: Path,
    result_root: Path,

    max_test_jobs: int = 300,

    monitor_interval: float = 5.0,
    reconcile_interval: float = 5.0,

    effective_runtime: dict | None = None,

    cancel_check=None,
) -> dict:

    def cancelled() -> bool:
        if cancel_check is None:
            return False

        try:
            return bool(
                cancel_check()
            )
        except Exception:
            return False

    policy = load_policy()

    workers_cfg = policy[
        "workers"
    ]

    execution = policy[
        "execution"
    ]

    effective = dict(
        effective_runtime
        or {}
    )

    effective_startup_timeout = float(
        effective.get(
            "startup_timeout",
            execution[
                "startup_timeout"
            ],
        )
    )

    effective_download_timeout = float(
        effective.get(
            "download_timeout",
            execution[
                "download_timeout"
            ],
        )
    )

    effective_upload_timeout = float(
        effective.get(
            "upload_timeout",
            execution[
                "upload_timeout"
            ],
        )
    )

    effective_runtime_retries = int(
        effective.get(
            "runtime_retries",
            execution[
                "runtime_retries"
            ],
        )
    )

    if effective_startup_timeout <= 0:
        raise ValueError(
            "effective startup timeout must be > 0"
        )

    if effective_download_timeout <= 0:
        raise ValueError(
            "effective download timeout must be > 0"
        )

    if effective_upload_timeout <= 0:
        raise ValueError(
            "effective upload timeout must be > 0"
        )

    if effective_runtime_retries < 0:
        raise ValueError(
            "effective runtime retries must be >= 0"
        )

    network_cfg = policy[
        "network_guard"
    ]

    project_cfg = policy[
        "project_guard"
    ]

    previous = load_json(
        metrics_path
    )

    baseline_ports = (
        discover_baseline_ports(
            [
                int(x)
                for x
                in project_cfg[
                    "candidate_ports"
                ]
            ]
        )
    )

    jobs = discover_jobs(
        Path(
            "/var/lib/config-location/configs"
        )
    )

    job_map = {
        job.config_id: job
        for job in jobs
    }

    state = load_state(
        queue_path
    )

    state = reconcile(
        state=state,
        jobs=jobs,
    )

    save_state(
        queue_path,
        state,
    )

    initial_count = len(
        job_map
    )

    resources, network, projects = (
        guard_snapshot(
            policy=policy,

            baseline_ports=
                baseline_ports,

            baseline_latency_ms=
                previous.get(
                    "baseline_latency_ms"
                ),
        )
    )

    initial_decision = decide(
        policy=policy,

        resources=resources,
        network=network,
        projects=projects,

        discovered=len(
            job_map
        ),

        previous_metrics=
            previous,
    )

    if initial_decision.pause:

        report = {
            "status":
                "PAUSED_SAFE",

            "reason":
                initial_decision.reason,

            "discovered":
                len(job_map),

            "initial_decision":
                initial_decision.__dict__,
        }

        atomic_json(
            report_path,
            report,
        )

        return report

    min_workers = int(
        workers_cfg[
            "min"
        ]
    )

    soft_max = int(
        workers_cfg[
            "soft_max"
        ]
    )

    hard_max = int(
        workers_cfg[
            "hard_max"
        ]
    )

    desired_workers = max(
        min_workers,
        min(
            hard_max,
            initial_decision.workers,
        ),
    )

    selected_target = min(
        max_test_jobs,

        max(
            1,
            initial_decision.batch_size,
        ),
    )

    result_store = (
        JsonHealthResultStore(
            result_root
        )
    )

    # FIX20.9 First-Health Coverage Scheduler.
    first_health_ratio = 0.75

    first_health_budget = max(
        1,
        int(
            selected_target
            * first_health_ratio
        ),
    )

    first_health_leased = 0

    latest_result_root = (
        result_root
        / "latest"
    )

    def has_health(
        config_id: str,
    ) -> bool:

        return (
            latest_result_root
            / f"{config_id}.json"
        ).is_file()

    def lease_for_coverage():
        nonlocal first_health_leased

        queue = state[
            "queue"
        ]

        if (
            first_health_leased
            < first_health_budget
        ):

            for index, candidate in enumerate(
                queue
            ):

                if not has_health(
                    candidate
                ):

                    cid = queue.pop(
                        index
                    )

                    if cid in state[
                        "leases"
                    ]:
                        raise RuntimeError(
                            "duplicate lease"
                        )

                    state[
                        "leases"
                    ].append(
                        cid
                    )

                    first_health_leased += 1

                    return cid

        return lease_next(
            state
        )

    active = {}

    pending_results = []

    attempted = 0
    committed = 0
    infra_requeued = 0

    healthy = 0
    unhealthy = 0
    errors = 0
    retries = 0

    new_configs_seen = 0
    removed_configs_seen = 0

    green_streak = 0

    worker_history = [
        {
            "time": 0,
            "workers":
                desired_workers,
            "reason":
                "initial",
        }
    ]

    rolling = deque(
        maxlen=50
    )

    last_network = network
    last_resources = resources
    last_projects = projects

    started = time.monotonic()

    next_monitor = (
        started
        + monitor_interval
    )

    next_reconcile = (
        started
        + reconcile_interval
    )

    monitor_pool = (
        ThreadPoolExecutor(
            max_workers=1,
            thread_name_prefix=
                "adaptive-monitor",
        )
    )

    monitor_future = None

    hard_pool = (
        ThreadPoolExecutor(
            max_workers=
                hard_max,

            thread_name_prefix=
                "adaptive-health",
        )
    )

    circuit_paused = False

    def persist_queue():

        save_state(
            queue_path,
            state,
        )

    def do_reconcile():

        nonlocal jobs
        nonlocal job_map
        nonlocal state
        nonlocal new_configs_seen
        nonlocal removed_configs_seen

        before = set(
            job_map
        )

        jobs = discover_jobs(
            Path(
                "/var/lib/config-location/configs"
            )
        )

        job_map = {
            job.config_id: job
            for job in jobs
        }

        after = set(
            job_map
        )

        new_configs_seen += len(
            after - before
        )

        removed_configs_seen += len(
            before - after
        )

        state = reconcile(
            state=state,
            jobs=jobs,
        )

        persist_queue()

    def flush_results():

        nonlocal pending_results
        nonlocal committed
        nonlocal infra_requeued
        nonlocal healthy
        nonlocal unhealthy
        nonlocal errors
        nonlocal retries
        nonlocal state

        if not pending_results:
            return

        failure_ratio = (
            sum(
                1
                for _cid, outcome
                in pending_results
                if traffic_failure(
                    outcome.result
                )
            )
            / len(
                pending_results
            )
        )

        correlated_infra = (
            last_network.degraded
            and
            failure_ratio
            >= float(
                network_cfg[
                    "correlated_failure_ratio"
                ]
            )
        )

        current_ids = set(
            job_map
        )

        for cid, outcome in pending_results:

            exists = (
                cid
                in current_ids
            )

            if (
                correlated_infra
                and traffic_failure(
                    outcome.result
                )
            ):

                requeue_lease(
                    state=state,
                    config_id=cid,
                    still_exists=exists,
                )

                infra_requeued += 1

                continue

            result_store.save(
                outcome.result
            )

            finish_lease(
                state=state,
                config_id=cid,
                still_exists=exists,
            )

            committed += 1

            retries += int(
                outcome.retries_used
            )

            if (
                outcome.result.state
                == HealthState.HEALTHY
            ):

                healthy += 1

            elif (
                outcome.result.state
                == HealthState.UNHEALTHY
            ):

                unhealthy += 1

            else:

                errors += 1

        pending_results = []

        persist_queue()

    try:

        while True:

            now = (
                time.monotonic()
            )

            # Live reconciliation.
            if now >= next_reconcile:

                flush_results()

                do_reconcile()

                next_reconcile = (
                    now
                    + reconcile_interval
                )

            # Start asynchronous monitoring.
            if (
                now >= next_monitor
                and monitor_future
                is None
            ):

                monitor_future = (
                    monitor_pool.submit(
                        guard_snapshot,

                        policy=policy,

                        baseline_ports=
                            baseline_ports,

                        baseline_latency_ms=
                            previous.get(
                                "baseline_latency_ms"
                            ),
                    )
                )

                next_monitor = (
                    now
                    + monitor_interval
                )

            # Apply completed monitor result.
            if (
                monitor_future
                is not None
                and monitor_future.done()
            ):

                (
                    last_resources,
                    last_network,
                    last_projects,
                ) = monitor_future.result()

                monitor_future = None

                flush_results()

                live_decision = decide(
                    policy=policy,

                    resources=
                        last_resources,

                    network=
                        last_network,

                    projects=
                        last_projects,

                    discovered=
                        len(job_map),

                    previous_metrics=
                        previous,
                )

                old_workers = (
                    desired_workers
                )

                if live_decision.pause:

                    circuit_paused = True
                    desired_workers = 0

                    green_streak = 0

                else:

                    circuit_paused = False

                    healthy_environment = (
                        not last_network.degraded
                        and
                        last_projects.healthy
                        and
                        last_resources.cpu_percent
                        < float(
                            policy[
                                "server_guard"
                            ][
                                "target_cpu_percent"
                            ]
                        )
                    )

                    if healthy_environment:

                        green_streak += 1

                    else:

                        green_streak = 0

                    base = max(
                        min_workers,
                        min(
                            hard_max,
                            live_decision.workers,
                        ),
                    )

                    if healthy_environment:

                        # Gradual ramp-up.
                        step = (
                            20
                            if green_streak >= 2
                            else 10
                        )

                        desired_workers = min(
                            hard_max,

                            max(
                                base,
                                desired_workers
                                + step,
                            ),
                        )

                        # Soft-max is not a fixed
                        # execution value. It is only
                        # the normal operating target.
                        if (
                            green_streak < 3
                            and desired_workers
                            > soft_max
                        ):

                            desired_workers = (
                                soft_max
                            )

                    else:

                        # Fast ramp-down under pressure.
                        desired_workers = max(
                            min_workers,

                            min(
                                base,

                                int(
                                    max(
                                        min_workers,
                                        desired_workers
                                        * 0.60,
                                    )
                                ),
                            ),
                        )

                if (
                    old_workers
                    != desired_workers
                ):

                    worker_history.append({
                        "time":
                            round(
                                now
                                - started,
                                2,
                            ),

                        "workers":
                            desired_workers,

                        "cpu":
                            round(
                                last_resources.cpu_percent,
                                2,
                            ),

                        "network_ratio":
                            last_network.success_ratio,

                        "network_degraded":
                            last_network.degraded,

                        "projects_ok":
                            last_projects.healthy,
                    })

            # Continuous refill.
            while (
                not circuit_paused
                and
                attempted
                < selected_target
                and
                len(active)
                < desired_workers
            ):

                cid = lease_for_coverage()

                if cid is None:

                    do_reconcile()

                    cid = lease_for_coverage()

                    if cid is None:
                        break

                job = job_map.get(
                    cid
                )

                if job is None:

                    requeue_lease(
                        state=state,
                        config_id=cid,
                        still_exists=False,
                    )

                    persist_queue()

                    continue

                future = hard_pool.submit(
                    run_health_with_retry,

                    config_id=
                        job.config_id,

                    config_type=
                        job.config_type,

                    source=
                        job.source,

                    startup_timeout=(
                        effective_startup_timeout
                    ),

                    download_timeout=(
                        effective_download_timeout
                    ),

                    upload_timeout=(
                        effective_upload_timeout
                    ),

                    upload_payload_bytes=int(
                        execution[
                            "upload_payload_bytes"
                        ]
                    ),

                    retry_count=(
                        effective_runtime_retries
                    ),

                    cancel_check=
                        cancel_check,
                )

                active[
                    future
                ] = cid

                attempted += 1

                persist_queue()

            # Exit once requested number has run
            # and no jobs remain active.
            if (
                attempted
                >= selected_target
                and not active
            ):

                break

            if not active:

                # Circuit breaker may be active.
                time.sleep(
                    0.10
                )

                continue

            done, _pending = wait(
                tuple(
                    active.keys()
                ),

                timeout=0.25,

                return_when=
                    FIRST_COMPLETED,
            )

            for future in done:

                cid = active.pop(
                    future
                )

                try:

                    outcome = (
                        future.result()
                    )

                except Exception:

                    # Keep the config in circulation.
                    requeue_lease(
                        state=state,
                        config_id=cid,
                        still_exists=(
                            cid in job_map
                        ),
                    )

                    persist_queue()

                    errors += 1

                    continue

                pending_results.append(
                    (
                        cid,
                        outcome,
                    )
                )

                rolling.append(
                    traffic_failure(
                        outcome.result
                    )
                )

            # Flush without introducing a barrier.
            if len(
                pending_results
            ) >= 25:

                flush_results()

        # Final monitor before final decision.
        if monitor_future is not None:

            (
                last_resources,
                last_network,
                last_projects,
            ) = monitor_future.result()

            monitor_future = None

        flush_results()

        # Final Store reconciliation includes
        # configs fetched while this run was active.
        do_reconcile()

        current_ids = set(
            job_map
        )

        assert_integrity(
            state=state,
            current_ids=current_ids,
        )

        if state["leases"]:

            raise RuntimeError(
                "leases remain after run"
            )

    finally:

        # SIGTERM-aware shutdown.
        #
        # Pending Health/monitor work must not keep the
        # always-on daemon blocked until systemd SIGKILL.
        #
        # Already-running jobs retain ownership of their
        # normal runtime finally/cleanup path.
        if cancelled():

            for future in list(active):
                try:
                    future.cancel()
                except Exception:
                    pass

            if monitor_future is not None:
                try:
                    monitor_future.cancel()
                except Exception:
                    pass

            hard_pool.shutdown(
                wait=False,
                cancel_futures=True,
            )

            monitor_pool.shutdown(
                wait=False,
                cancel_futures=True,
            )

        else:

            hard_pool.shutdown(
                wait=True,
            )

            monitor_pool.shutdown(
                wait=True,
            )

    duration = (
        time.monotonic()
        - started
    )

    jobs_per_second = (
        committed
        / max(
            0.001,
            duration,
        )
    )

    latency_values = [
        x
        for x in (
            previous.get(
                "baseline_latency_ms"
            ),

            last_network.median_latency_ms,
        )
        if (
            isinstance(
                x,
                (
                    int,
                    float,
                ),
            )
            and x > 0
        )
    ]

    baseline_latency = (
        sum(
            latency_values
        )
        / len(
            latency_values
        )
        if latency_values
        else None
    )

    metrics = {
        "workers":
            max(
                1,
                desired_workers,
            ),

        "completed":
            committed,

        "jobs_per_second":
            jobs_per_second,

        "duration_seconds":
            duration,

        "error_ratio":
            errors
            / max(
                1,
                attempted,
            ),

        "infra_ratio":
            infra_requeued
            / max(
                1,
                attempted,
            ),

        "baseline_latency_ms":
            baseline_latency,

        "estimated_worker_mbps":
            previous.get(
                "estimated_worker_mbps",
                1.5,
            ),
    }

    atomic_json(
        metrics_path,
        metrics,
    )

    report = {
        "status":
            (
                "COMPLETE"
                if attempted
                == selected_target
                else "PARTIAL_SAFE"
            ),

        "initial_discovered":
            initial_count,

        "final_discovered":
            len(job_map),

        "new_configs_seen":
            new_configs_seen,

        "removed_configs_seen":
            removed_configs_seen,

        "selected_target":
            selected_target,

        "attempted":
            attempted,

        "committed":
            committed,

        "infra_requeued":
            infra_requeued,

        "healthy":
            healthy,

        "unhealthy":
            unhealthy,

        "error":
            errors,

        "retries":
            retries,

        "duration_seconds":
            duration,

        "jobs_per_second":
            jobs_per_second,

        "worker_history":
            worker_history,

        "final_workers":
            desired_workers,

        "final_cpu":
            last_resources.cpu_percent,

        "final_network":
            last_network.__dict__,

        "final_projects":
            last_projects.__dict__,

        "queue_size":
            len(
                state["queue"]
            ),

        "leases":
            len(
                state["leases"]
            ),

        "effective_runtime_used": {
            "startup_timeout":
                effective_startup_timeout,

            "download_timeout":
                effective_download_timeout,

            "upload_timeout":
                effective_upload_timeout,

            "runtime_retries":
                effective_runtime_retries,

            "profile":
                effective.get(
                    "profile",
                    "policy-default",
                ),
        },
    }

    atomic_json(
        report_path,
        report,
    )

    return report
