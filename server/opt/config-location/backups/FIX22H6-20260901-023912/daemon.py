from __future__ import annotations

import os
import signal
import time
import traceback

from datetime import datetime, timezone

from .worker import (
    run_country_worker_once,
)


STOP=False


def utc_now() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def handle_signal(
    signum,
    frame,
):
    global STOP

    STOP=True

    print(
        "COUNTRY_DAEMON_SIGNAL",
        signum,
        flush=True,
    )


def env_int(
    name: str,
    default: int,
    *,
    minimum: int,
    maximum: int,
) -> int:

    raw=os.environ.get(
        name,
        str(default),
    )

    try:
        value=int(raw)
    except Exception:
        value=default

    return max(
        minimum,
        min(
            maximum,
            value,
        ),
    )


def main() -> int:

    signal.signal(
        signal.SIGTERM,
        handle_signal,
    )

    signal.signal(
        signal.SIGINT,
        handle_signal,
    )


    max_jobs=env_int(
        "COUNTRY_MAX_JOBS_PER_CYCLE",
        3,
        minimum=1,
        maximum=10,
    )

    interval=env_int(
        "COUNTRY_CYCLE_INTERVAL",
        45,
        minimum=15,
        maximum=3600,
    )


    print(
        "COUNTRY_SHADOW_DAEMON_START",
        "max_jobs=",
        max_jobs,
        "interval=",
        interval,
        "mode=shadow",
        flush=True,
    )


    cycle=0


    while not STOP:

        cycle += 1

        started=time.monotonic()


        try:

            report=run_country_worker_once(
                max_jobs=max_jobs
            )


            print(
                "COUNTRY_CYCLE",
                cycle,
                "time=",
                utc_now(),
                "eligible=",
                report.get(
                    "eligible_due"
                ),
                "selected=",
                report.get(
                    "selected"
                ),
                "processed=",
                report.get(
                    "processed"
                ),
                "states=",
                report.get(
                    "states"
                ),
                flush=True,
            )


        except RuntimeError as e:

            # A second Country worker must never
            # fight with the active owner.
            if str(e)==(
                "country_worker_already_running"
            ):

                print(
                    "COUNTRY_CYCLE_LOCKED",
                    cycle,
                    flush=True,
                )

            else:

                print(
                    "COUNTRY_CYCLE_RUNTIME_ERROR",
                    cycle,
                    repr(e),
                    flush=True,
                )


        except Exception as e:

            # Country failure must never terminate
            # Fetcher or Health services.
            print(
                "COUNTRY_CYCLE_ERROR",
                cycle,
                type(e).__name__,
                str(e)[:500],
                flush=True,
            )

            traceback.print_exc()


        elapsed=(
            time.monotonic()
            - started
        )


        remaining=max(
            0.0,
            interval-elapsed,
        )


        # Sleep interruptibly so systemd stop
        # does not have to wait a whole interval.
        end=time.monotonic()+remaining

        while (
            not STOP
            and time.monotonic()<end
        ):
            time.sleep(
                min(
                    1.0,
                    end-time.monotonic(),
                )
            )


    print(
        "COUNTRY_SHADOW_DAEMON_STOP",
        "cycles=",
        cycle,
        flush=True,
    )

    return 0


if __name__=="__main__":
    raise SystemExit(
        main()
    )
