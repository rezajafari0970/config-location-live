from __future__ import annotations

import json
import os
import signal
import time
import traceback

from dataclasses import asdict
from pathlib import Path

from .adaptive_controller import (
    collect_projects,
    collect_resources,
    decide,
    discover_baseline_ports,
    load_policy,
)

from .adaptive_network import (
    collect_network_parallel,
)

from .production_adaptive import (
    run_production_adaptive_once,
)

from .production_scheduler import (
    discover_jobs,
)


STORE = Path(
    "/var/lib/config-location/configs"
)

STATE_ROOT = Path(
    "/var/lib/config-location/"
    "health-adaptive"
)

LOG_ROOT = Path(
    "/var/log/config-location/"
    "health-adaptive"
)

STATUS_FILE = (
    STATE_ROOT / "daemon-status.json"
)

EFFECTIVE_FILE = (
    STATE_ROOT / "effective-runtime.json"
)

METRICS_FILE = (
    STATE_ROOT / "metrics.json"
)

STOP = False


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

        value = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

        if isinstance(
            value,
            dict,
        ):
            return value

    except Exception:
        pass

    return {}


def now() -> float:

    return time.time()


def handle_signal(
    signum,
    frame,
):

    global STOP

    STOP = True


signal.signal(
    signal.SIGTERM,
    handle_signal,
)

signal.signal(
    signal.SIGINT,
    handle_signal,
)


def effective_runtime(
    *,
    policy: dict,
    network,
    resources,
    previous: dict,
) -> dict:
    """
    Produce adaptive operational values.

    The current Health runner still owns the
    hard Xray/probe contract. These values are
    used by the control loop for cycle pacing
    and future Panel visibility.
    """

    base = policy[
        "execution"
    ]

    latency = (
        network.median_latency_ms
        if network.median_latency_ms
        is not None
        else previous.get(
            "baseline_latency_ms",
            150,
        )
    )

    latency = max(
        1.0,
        float(latency),
    )


    if network.critical:

        profile = "critical"

        startup_timeout = max(
            12.0,
            float(
                base[
                    "startup_timeout"
                ]
            ),
        )

        download_timeout = max(
            15.0,
            float(
                base[
                    "download_timeout"
                ]
            ),
        )

        upload_timeout = max(
            15.0,
            float(
                base[
                    "upload_timeout"
                ]
            ),
        )

        retries = max(
            5,
            int(
                base[
                    "runtime_retries"
                ]
            ),
        )


    elif network.degraded:

        profile = "degraded"

        factor = min(
            2.5,
            max(
                1.5,
                latency / 150.0,
            ),
        )

        startup_timeout = min(
            15.0,
            max(
                8.0,
                float(
                    base[
                        "startup_timeout"
                    ]
                )
                * factor,
            ),
        )

        download_timeout = min(
            18.0,
            max(
                9.0,
                float(
                    base[
                        "download_timeout"
                    ]
                )
                * factor,
            ),
        )

        upload_timeout = min(
            18.0,
            max(
                9.0,
                float(
                    base[
                        "upload_timeout"
                    ]
                )
                * factor,
            ),
        )

        retries = max(
            4,
            int(
                base[
                    "runtime_retries"
                ]
            ),
        )


    else:

        profile = "normal"

        startup_timeout = float(
            base[
                "startup_timeout"
            ]
        )

        download_timeout = float(
            base[
                "download_timeout"
            ]
        )

        upload_timeout = float(
            base[
                "upload_timeout"
            ]
        )

        retries = int(
            base[
                "runtime_retries"
            ]
        )


    return {
        "profile":
            profile,

        "latency_ms":
            latency,

        "startup_timeout":
            round(
                startup_timeout,
                2,
            ),

        "download_timeout":
            round(
                download_timeout,
                2,
            ),

        "upload_timeout":
            round(
                upload_timeout,
                2,
            ),

        "runtime_retries":
            retries,

        "cpu_percent":
            resources.cpu_percent,

        "network_success_ratio":
            network.success_ratio,

        "network_degraded":
            network.degraded,

        "network_critical":
            network.critical,
    }


def sleep_interruptible(
    seconds: float,
) -> None:

    deadline = (
        time.monotonic()
        + max(
            0.0,
            seconds,
        )
    )

    while (
        not STOP
        and time.monotonic()
        < deadline
    ):

        time.sleep(
            min(
                0.5,
                max(
                    0.0,
                    deadline
                    - time.monotonic(),
                ),
            )
        )


def main() -> int:

    STATE_ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )

    LOG_ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )

    policy = load_policy()

    project_cfg = policy[
        "project_guard"
    ]

    network_cfg = policy[
        "network_guard"
    ]

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


    cycles = 0
    consecutive_errors = 0
    safe_idle_cycles = 0

    started_at = now()


    while not STOP:

        cycle_started = (
            time.monotonic()
        )

        cycles += 1

        previous = load_json(
            METRICS_FILE
        )


        status = {
            "running":
                True,

            "pid":
                os.getpid(),

            "started_at":
                started_at,

            "cycle":
                cycles,

            "cycle_started_at":
                now(),

            "state":
                "preflight",
        }


        try:

            # Reload policy every cycle so Panel
            # changes take effect without restart.
            policy = load_policy()

            resources = (
                collect_resources()
            )

            network = (
                collect_network_parallel(
                    timeout_seconds=float(
                        network_cfg[
                            "probe_timeout_seconds"
                        ]
                    ),

                    baseline_latency_ms=
                        previous.get(
                            "baseline_latency_ms"
                        ),

                    degraded_multiplier=float(
                        network_cfg[
                            "latency_degraded_multiplier"
                        ]
                    ),

                    minimum_success_ratio=float(
                        network_cfg[
                            "minimum_direct_success_ratio"
                        ]
                    ),

                    critical_success_ratio=float(
                        network_cfg[
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
                        in project_cfg[
                            "services"
                        ]
                    ],

                    baseline_ports=
                        baseline_ports,
                )
            )


            jobs = discover_jobs(
                STORE
            )


            decision = decide(
                policy=policy,

                resources=
                    resources,

                network=
                    network,

                projects=
                    projects,

                discovered=
                    len(jobs),

                previous_metrics=
                    previous,
            )


            runtime = effective_runtime(
                policy=policy,

                network=network,

                resources=
                    resources,

                previous=
                    previous,
            )


            atomic_json(
                EFFECTIVE_FILE,
                runtime,
            )


            status.update({
                "discovered":
                    len(jobs),

                "resources":
                    asdict(
                        resources
                    ),

                "network":
                    asdict(
                        network
                    ),

                "projects":
                    asdict(
                        projects
                    ),

                "decision":
                    asdict(
                        decision
                    ),

                "effective_runtime":
                    runtime,
            })


            if decision.pause:

                safe_idle_cycles += 1

                status[
                    "state"
                ] = "safe_idle"

                status[
                    "safe_idle_reason"
                ] = decision.reason

                status[
                    "last_completed_at"
                ] = now()

                atomic_json(
                    STATUS_FILE,
                    status,
                )


                # Do not spin when infrastructure
                # is unhealthy.
                #
                # Network critical:
                # short retry.
                #
                # Protected project failure:
                # slightly slower retry.
                if (
                    decision.reason
                    == "global_network_critical"
                ):

                    sleep_interruptible(
                        5.0
                    )

                else:

                    sleep_interruptible(
                        10.0
                    )

                continue


            safe_idle_cycles = 0


            # This is only a ceiling.
            # The inner adaptive controller may
            # select a smaller target.
            max_jobs = min(
                3000,
                max(
                    50,
                    int(
                        decision.batch_size
                    ),
                ),
            )


            status[
                "state"
            ] = "running_health"

            status[
                "max_jobs_ceiling"
            ] = max_jobs

            atomic_json(
                STATUS_FILE,
                status,
            )


            report = (
                run_production_adaptive_once(
                    max_jobs=max_jobs,
                    effective_runtime=runtime,
                    cancel_check=lambda: STOP,
                )
            )


            consecutive_errors = 0


            status.update({
                "state":
                    "cycle_complete",

                "last_report":
                    report,

                "last_completed_at":
                    now(),

                "cycle_duration_seconds":
                    (
                        time.monotonic()
                        - cycle_started
                    ),

                "consecutive_errors":
                    consecutive_errors,

                "safe_idle_cycles":
                    safe_idle_cycles,
            })


            atomic_json(
                STATUS_FILE,
                status,
            )


            # Always-on does NOT mean busy-loop.
            #
            # If configs are flowing quickly,
            # a short gap is enough to let Fetcher
            # and other projects breathe.
            #
            # Under degraded conditions, increase
            # idle time automatically.
            if network.degraded:

                sleep_interruptible(
                    5.0
                )

            elif (
                resources.cpu_percent
                > float(
                    policy[
                        "server_guard"
                    ][
                        "target_cpu_percent"
                    ]
                )
            ):

                sleep_interruptible(
                    3.0
                )

            else:

                sleep_interruptible(
                    1.0
                )


        except Exception as exc:

            consecutive_errors += 1

            status.update({
                "state":
                    "cycle_error",

                "error_type":
                    type(
                        exc
                    ).__name__,

                "error":
                    str(exc)[
                        :1000
                    ],

                "traceback":
                    traceback.format_exc()[
                        -5000:
                    ],

                "consecutive_errors":
                    consecutive_errors,

                "last_completed_at":
                    now(),
            })


            atomic_json(
                STATUS_FILE,
                status,
            )


            # Exponential but bounded backoff.
            backoff = min(
                60.0,
                float(
                    2 ** min(
                        consecutive_errors,
                        5,
                    )
                ),
            )


            sleep_interruptible(
                backoff
            )


    final = load_json(
        STATUS_FILE
    )

    final.update({
        "running":
            False,

        "state":
            "stopped",

        "stopped_at":
            now(),
    })

    atomic_json(
        STATUS_FILE,
        final,
    )

    return 0


if __name__ == "__main__":

    raise SystemExit(
        main()
    )
