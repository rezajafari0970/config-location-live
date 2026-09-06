from __future__ import annotations

import signal
import time
import traceback

from datetime import (
    datetime,
    timezone,
)

from .adaptive import (
    decide_adaptive_rate,
)

from .worker import (
    run_country_worker_adaptive,
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


def main() -> int:

    signal.signal(
        signal.SIGTERM,
        handle_signal,
    )

    signal.signal(
        signal.SIGINT,
        handle_signal,
    )


    print(
        "COUNTRY_ADAPTIVE_DAEMON_START",
        "mode=adaptive",
        flush=True,
    )


    cycle=0


    while not STOP:

        cycle+=1


        decision=(
            decide_adaptive_rate()
        )


        print(
            "COUNTRY_ADAPTIVE_DECISION",
            "cycle=",
            cycle,
            "level=",
            decision.level,
            "concurrency=",
            decision.concurrency,
            "max_jobs=",
            decision.max_jobs,
            "interval=",
            decision.interval,
            "load_ratio=",
            round(
                decision.load_ratio,
                3,
            ),
            "health_runtimes=",
            decision.health_runtime_count,
            "reason=",
            decision.reason,
            flush=True,
        )


        started=time.monotonic()


        try:

            report=(
                run_country_worker_adaptive(
                    max_jobs=
                        decision.max_jobs,

                    concurrency=
                        decision.concurrency,
                )
            )


            print(
                "COUNTRY_ADAPTIVE_CYCLE",
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
                "concurrency=",
                report.get(
                    "concurrency"
                ),
                "states=",
                report.get(
                    "states"
                ),
                flush=True,
            )


        except RuntimeError as e:

            if str(e)==(
                "country_worker_already_running"
            ):

                print(
                    "COUNTRY_ADAPTIVE_LOCKED",
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

        wait=max(
            0.0,
            decision.interval
            - elapsed,
        )


        end=(
            time.monotonic()
            + wait
        )


        while (
            not STOP
            and
            time.monotonic()
            < end
        ):

            time.sleep(
                min(
                    0.5,
                    end
                    - time.monotonic(),
                )
            )


    print(
        "COUNTRY_ADAPTIVE_DAEMON_STOP",
        "cycles=",
        cycle,
        flush=True,
    )

    return 0


if __name__=="__main__":

    raise SystemExit(
        main()
    )
