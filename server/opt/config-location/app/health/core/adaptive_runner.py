from __future__ import annotations

import json
import os
import time

from collections import Counter
from concurrent.futures import (
    ThreadPoolExecutor,
    as_completed,
)

from pathlib import Path

from .adaptive_controller import (
    collect_network,
    collect_projects,
    collect_resources,
    decide,
    discover_baseline_ports,
    load_policy,
)

from .adaptive_queue import (
    commit_completed,
    load_queue,
    peek,
    reconcile_queue,
    save_queue,
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

    tmp.chmod(
        0o600
    )

    os.replace(
        tmp,
        path,
    )


def _load_json(
    path: Path,
) -> dict:

    if not path.exists():
        return {}

    try:

        value = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

        return (
            value
            if isinstance(
                value,
                dict,
            )
            else {}
        )

    except Exception:
        return {}


def _traffic_failure_reason(
    result,
) -> str | None:

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

    if reason in (
        "download_failed",
        "upload_failed",
    ):
        return str(reason)

    return None


def run_adaptive_test(
    *,
    queue_path: Path,
    metrics_path: Path,
    report_path: Path,

    result_root: Path,

    max_test_jobs: int = 300,
) -> dict:

    policy = (
        load_policy()
    )

    execution = (
        policy["execution"]
    )

    network_policy = (
        policy[
            "network_guard"
        ]
    )

    project_policy = (
        policy[
            "project_guard"
        ]
    )


    jobs = discover_jobs(
        Path(
            "/var/lib/config-location/configs"
        )
    )

    job_map = {
        job.config_id:
            job
        for job in jobs
    }


    queue = reconcile_queue(
        existing_queue=(
            load_queue(
                queue_path
            )
        ),
        jobs=jobs,
    )

    save_queue(
        queue_path,
        queue,
    )


    previous = (
        _load_json(
            metrics_path
        )
    )


    baseline_ports = (
        discover_baseline_ports(
            [
                int(x)
                for x
                in project_policy[
                    "candidate_ports"
                ]
            ]
        )
    )


    resources = (
        collect_resources()
    )


    network = collect_network(
        timeout_seconds=float(
            network_policy[
                "probe_timeout_seconds"
            ]
        ),

        baseline_latency_ms=(
            previous.get(
                "baseline_latency_ms"
            )
        ),

        degraded_multiplier=float(
            network_policy[
                "latency_degraded_multiplier"
            ]
        ),

        minimum_success_ratio=float(
            network_policy[
                "minimum_direct_success_ratio"
            ]
        ),

        critical_success_ratio=float(
            network_policy[
                "critical_direct_success_ratio"
            ]
        ),
    )


    projects = collect_projects(
        services=[
            str(x)
            for x
            in project_policy[
                "services"
            ]
        ],

        baseline_ports=
            baseline_ports,
    )


    decision = decide(
        policy=policy,

        resources=resources,
        network=network,
        projects=projects,

        discovered=len(jobs),

        previous_metrics=
            previous,
    )


    selected_count = min(
        decision.batch_size,
        max_test_jobs,
        len(queue),
    )


    report = {
        "discovered":
            len(jobs),

        "queue_length":
            len(queue),

        "baseline_ports":
            list(
                baseline_ports
            ),

        "resource_before":
            resources.__dict__,

        "network_before":
            network.__dict__,

        "projects_before":
            projects.__dict__,

        "adaptive_decision":
            decision.__dict__,

        "test_job_cap":
            max_test_jobs,

        "selected":
            selected_count,

        "waves":
            [],
    }


    if decision.pause:

        report[
            "status"
        ] = "PAUSED_SAFE"

        _atomic_json(
            report_path,
            report,
        )

        return report


    selected_ids = peek(
        queue,
        selected_count,
    )


    result_store = (
        JsonHealthResultStore(
            result_root
        )
    )


    started = (
        time.monotonic()
    )


    committed_ids = []

    healthy_total = 0
    unhealthy_total = 0
    error_total = 0
    retries_total = 0


    offset = 0


    while offset < len(
        selected_ids
    ):

        # Re-sample before every wave.
        resources_now = (
            collect_resources()
        )

        previous_latency = (
            previous.get(
                "baseline_latency_ms"
            )
        )


        network_now = collect_network(
            timeout_seconds=float(
                network_policy[
                    "probe_timeout_seconds"
                ]
            ),

            baseline_latency_ms=(
                previous_latency
            ),

            degraded_multiplier=float(
                network_policy[
                    "latency_degraded_multiplier"
                ]
            ),

            minimum_success_ratio=float(
                network_policy[
                    "minimum_direct_success_ratio"
                ]
            ),

            critical_success_ratio=float(
                network_policy[
                    "critical_direct_success_ratio"
                ]
            ),
        )


        projects_now = (
            collect_projects(
                services=[
                    str(x)
                    for x
                    in project_policy[
                        "services"
                    ]
                ],

                baseline_ports=
                    baseline_ports,
            )
        )


        live_decision = decide(
            policy=policy,

            resources=
                resources_now,

            network=
                network_now,

            projects=
                projects_now,

            discovered=
                len(jobs),

            previous_metrics=
                previous,
        )


        if live_decision.pause:

            report[
                "waves"
            ].append({
                "status":
                    "CIRCUIT_BREAK",

                "reason":
                    live_decision.reason,

                "offset":
                    offset,
            })

            break


        wave_workers = min(
            live_decision.workers,

            int(
                execution[
                    "wave_max"
                ]
            ),

            (
                len(selected_ids)
                - offset
            ),
        )


        wave_workers = max(
            int(
                execution[
                    "minimum_wave"
                ]
            ),
            wave_workers,
        )


        wave_size = min(
            wave_workers,
            len(selected_ids)
            - offset,
        )


        wave_ids = (
            selected_ids[
                offset:
                offset
                + wave_size
            ]
        )


        outcomes = []


        with ThreadPoolExecutor(
            max_workers=
                wave_workers,

            thread_name_prefix=
                "adaptive-health",
        ) as pool:

            futures = {
                pool.submit(
                    run_health_with_retry,

                    config_id=
                        job_map[
                            config_id
                        ].config_id,

                    config_type=
                        job_map[
                            config_id
                        ].config_type,

                    source=
                        job_map[
                            config_id
                        ].source,

                    startup_timeout=float(
                        execution[
                            "startup_timeout"
                        ]
                    ),

                    download_timeout=float(
                        execution[
                            "download_timeout"
                        ]
                    ),

                    upload_timeout=float(
                        execution[
                            "upload_timeout"
                        ]
                    ),

                    upload_payload_bytes=int(
                        execution[
                            "upload_payload_bytes"
                        ]
                    ),

                    retry_count=int(
                        execution[
                            "runtime_retries"
                        ]
                    ),
                ): config_id

                for config_id
                in wave_ids
            }


            for future in as_completed(
                futures
            ):

                config_id = (
                    futures[
                        future
                    ]
                )

                outcome = (
                    future.result()
                )

                outcomes.append(
                    (
                        config_id,
                        outcome,
                    )
                )


        # Restore deterministic queue order.
        outcome_map = {
            config_id:
                outcome

            for config_id, outcome
            in outcomes
        }


        ordered = [
            (
                config_id,
                outcome_map[
                    config_id
                ],
            )

            for config_id
            in wave_ids
        ]


        traffic_failures = sum(
            1
            for _config_id, outcome
            in ordered
            if _traffic_failure_reason(
                outcome.result
            )
        )


        failure_ratio = (
            traffic_failures
            / max(
                1,
                len(ordered),
            )
        )


        # Re-check direct Internet after the wave.
        network_after = collect_network(
            timeout_seconds=float(
                network_policy[
                    "probe_timeout_seconds"
                ]
            ),

            baseline_latency_ms=(
                previous_latency
            ),

            degraded_multiplier=float(
                network_policy[
                    "latency_degraded_multiplier"
                ]
            ),

            minimum_success_ratio=float(
                network_policy[
                    "minimum_direct_success_ratio"
                ]
            ),

            critical_success_ratio=float(
                network_policy[
                    "critical_direct_success_ratio"
                ]
            ),
        )


        correlated = (
            failure_ratio
            >= float(
                network_policy[
                    "correlated_failure_ratio"
                ]
            )
            and network_after.degraded
        )


        if correlated:

            # IMPORTANT:
            # These results are NOT committed as
            # production-style health failures.
            # Queue is NOT advanced. They will be
            # retried later.
            report[
                "waves"
            ].append({
                "status":
                    "INFRA_DEGRADED_ROLLBACK",

                "wave_size":
                    len(ordered),

                "traffic_failure_ratio":
                    failure_ratio,

                "network_after":
                    network_after.__dict__,
            })

            break


        # Commit only after infrastructure checks
        # pass for the complete wave.
        for config_id, outcome in ordered:

            result_store.save(
                outcome.result
            )

            committed_ids.append(
                config_id
            )

            retries_total += int(
                outcome.retries_used
            )


            if (
                outcome.result.state
                == HealthState.HEALTHY
            ):

                healthy_total += 1

            elif (
                outcome.result.state
                == HealthState.UNHEALTHY
            ):

                unhealthy_total += 1

            else:

                error_total += 1


        queue = commit_completed(
            queue=queue,
            completed_ids=wave_ids,
        )

        save_queue(
            queue_path,
            queue,
        )


        report[
            "waves"
        ].append({
            "status":
                "COMMITTED",

            "wave_size":
                len(ordered),

            "workers":
                wave_workers,

            "healthy":
                sum(
                    1
                    for _id, o
                    in ordered
                    if (
                        o.result.state
                        == HealthState.HEALTHY
                    )
                ),

            "unhealthy":
                sum(
                    1
                    for _id, o
                    in ordered
                    if (
                        o.result.state
                        == HealthState.UNHEALTHY
                    )
                ),

            "error":
                sum(
                    1
                    for _id, o
                    in ordered
                    if (
                        o.result.state
                        == HealthState.ERROR
                    )
                ),

            "traffic_failure_ratio":
                failure_ratio,

            "network_after":
                network_after.__dict__,
        })


        offset += len(
            wave_ids
        )


    duration = max(
        0.001,
        time.monotonic()
        - started,
    )


    completed = len(
        committed_ids
    )


    jobs_per_second = (
        completed
        / duration
    )


    error_ratio = (
        error_total
        / max(
            1,
            completed,
        )
    )


    baseline_values = [
        x
        for x in (
            previous.get(
                "baseline_latency_ms"
            ),
            network.median_latency_ms,
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
            baseline_values
        )
        / len(
            baseline_values
        )
        if baseline_values
        else None
    )


    metrics = {
        "workers":
            decision.workers,

        "completed":
            completed,

        "duration_seconds":
            duration,

        "jobs_per_second":
            jobs_per_second,

        "error_ratio":
            error_ratio,

        "infra_ratio":
            0.0,

        "baseline_latency_ms":
            baseline_latency,

        # Conservative initial estimate; later
        # production runs can refine this.
        "estimated_worker_mbps":
            previous.get(
                "estimated_worker_mbps",
                1.5,
            ),
    }


    _atomic_json(
        metrics_path,
        metrics,
    )


    report.update({
        "status":
            (
                "COMPLETE"
                if completed
                == selected_count
                else "PARTIAL_SAFE"
            ),

        "completed":
            completed,

        "healthy":
            healthy_total,

        "unhealthy":
            unhealthy_total,

        "error":
            error_total,

        "retries":
            retries_total,

        "duration_seconds":
            duration,

        "jobs_per_second":
            jobs_per_second,

        "queue_remaining":
            len(queue),
    })


    _atomic_json(
        report_path,
        report,
    )


    return report
