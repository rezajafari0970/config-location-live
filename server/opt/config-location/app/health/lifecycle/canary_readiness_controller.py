from __future__ import annotations

import fcntl
import json
import os
import signal
import tempfile
import time
import traceback

from datetime import (
    datetime,
    timezone,
)

from pathlib import Path
from typing import Any

from app.health.lifecycle.canary_removal_harness import (
    run_failclosed_harness,
)


STATUS_PATH = Path(
    "/var/lib/config-location/"
    "canary-readiness/status.json"
)

LOCK_PATH = Path(
    "/run/config-location-canary-readiness/"
    "controller.lock"
)

CYCLE_SECONDS = 30

PRODUCTION_DELETE = False

_shutdown = False


def now_iso() -> str:
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


def read_json(
    path: Path,
) -> Any:

    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )

    except Exception:
        return {}


def atomic_json(
    path: Path,
    value: dict[str,Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd,tmp=tempfile.mkstemp(
        dir=str(path.parent),
        prefix="."+path.name+".",
        suffix=".tmp",
    )

    try:

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as fh:

            json.dump(
                value,
                fh,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            fh.write("\n")
            fh.flush()
            os.fsync(
                fh.fileno()
            )

        try:
            gid=path.parent.stat().st_gid

            os.chown(
                tmp,
                -1,
                gid,
            )
        except Exception:
            pass

        os.chmod(
            tmp,
            0o640,
        )

        os.replace(
            tmp,
            path,
        )

    finally:

        if os.path.exists(tmp):
            os.unlink(tmp)


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

    STATUS_PATH.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    LOCK_PATH.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd=os.open(
        LOCK_PATH,
        os.O_CREAT | os.O_RDWR,
        0o600,
    )

    try:

        try:
            fcntl.flock(
                fd,
                fcntl.LOCK_EX
                | fcntl.LOCK_NB,
            )

        except BlockingIOError:

            atomic_json(
                STATUS_PATH,
                {
                    "component":
                        "canary-readiness-controller",

                    "state":
                        "BLOCKED",

                    "reason":
                        "controller_already_running",

                    "production_delete":
                        False,

                    "delete_performed":
                        False,

                    "updated_at":
                        now_iso(),
                },
            )

            return 2


        cycle=0

        total_cycles=0
        total_waiting=0
        total_blocked=0
        total_canary_ready=0
        total_errors=0

        last_transition=None


        atomic_json(
            STATUS_PATH,
            {
                "component":
                    "canary-readiness-controller",

                "mode":
                    "permanent_fail_closed",

                "state":
                    "starting",

                "production_delete":
                    False,

                "delete_performed":
                    False,

                "cycle_seconds":
                    CYCLE_SECONDS,

                "hard_boundary":
                    "NO_DELETE",

                "pid":
                    os.getpid(),

                "started_at":
                    now_iso(),

                "updated_at":
                    now_iso(),
            },
        )


        previous_state=None


        while not _shutdown:

            cycle += 1
            total_cycles += 1

            cycle_started=time.time()


            try:

                result=run_failclosed_harness()

                state=str(
                    result.get(
                        "state",
                        "BLOCKED",
                    )
                )


                # Fail closed on any unexpected state.
                if state not in {
                    "WAITING_NO_CANDIDATE",
                    "BLOCKED",
                    "CANARY_READY",
                }:

                    state="BLOCKED"

                    result={
                        "state":
                            "BLOCKED",

                        "reason":
                            "unexpected_harness_state",

                        "production_delete":
                            False,

                        "delete_performed":
                            False,
                    }


                # Hard safety assertions.
                if (
                    result.get(
                        "production_delete"
                    )
                    is not False
                ):

                    state="BLOCKED"

                    result={
                        "state":
                            "BLOCKED",

                        "reason":
                            "production_delete_boundary_violation",

                        "production_delete":
                            False,

                        "delete_performed":
                            False,
                    }


                if (
                    result.get(
                        "delete_performed"
                    )
                    is not False
                ):

                    state="BLOCKED"

                    result={
                        "state":
                            "BLOCKED",

                        "reason":
                            "unexpected_delete_signal",

                        "production_delete":
                            False,

                        "delete_performed":
                            False,
                    }


                if state=="WAITING_NO_CANDIDATE":
                    total_waiting += 1

                elif state=="BLOCKED":
                    total_blocked += 1

                elif state=="CANARY_READY":
                    total_canary_ready += 1


                if state != previous_state:

                    last_transition={
                        "from":
                            previous_state,

                        "to":
                            state,

                        "at":
                            now_iso(),
                    }

                    previous_state=state


                elapsed=(
                    time.time()
                    - cycle_started
                )


                status={
                    "component":
                        "canary-readiness-controller",

                    "mode":
                        "permanent_fail_closed",

                    "state":
                        state,

                    "production_delete":
                        False,

                    "delete_performed":
                        False,

                    "hard_boundary":
                        "NO_DELETE",

                    "cycle":
                        cycle,

                    "cycle_seconds":
                        CYCLE_SECONDS,

                    "cycle_elapsed_seconds":
                        round(
                            elapsed,
                            3,
                        ),

                    "harness_result":
                        result,

                    "candidate":
                        result.get(
                            "candidate"
                        ),

                    "gates":
                        result.get(
                            "gates",
                            {},
                        ),

                    "reason":
                        result.get(
                            "reason"
                        ),

                    "total_cycles":
                        total_cycles,

                    "total_waiting":
                        total_waiting,

                    "total_blocked":
                        total_blocked,

                    "total_canary_ready":
                        total_canary_ready,

                    "total_errors":
                        total_errors,

                    "last_transition":
                        last_transition,

                    "last_error":
                        None,

                    "pid":
                        os.getpid(),

                    "updated_at":
                        now_iso(),
                }


                atomic_json(
                    STATUS_PATH,
                    status,
                )


            except Exception as exc:

                total_errors += 1
                total_blocked += 1

                state="BLOCKED"

                last_transition={
                    "from":
                        previous_state,

                    "to":
                        "BLOCKED",

                    "at":
                        now_iso(),
                }

                previous_state="BLOCKED"


                atomic_json(
                    STATUS_PATH,
                    {
                        "component":
                            "canary-readiness-controller",

                        "mode":
                            "permanent_fail_closed",

                        "state":
                            "BLOCKED",

                        "reason":
                            "controller_exception",

                        "production_delete":
                            False,

                        "delete_performed":
                            False,

                        "hard_boundary":
                            "NO_DELETE",

                        "cycle":
                            cycle,

                        "total_cycles":
                            total_cycles,

                        "total_waiting":
                            total_waiting,

                        "total_blocked":
                            total_blocked,

                        "total_canary_ready":
                            total_canary_ready,

                        "total_errors":
                            total_errors,

                        "last_transition":
                            last_transition,

                        "last_error": {
                            "exception":
                                repr(exc),

                            "traceback":
                                traceback.format_exc()[
                                    -5000:
                                ],
                        },

                        "pid":
                            os.getpid(),

                        "updated_at":
                            now_iso(),
                    },
                )


            sleep_interruptible(
                CYCLE_SECONDS
            )


        current=read_json(
            STATUS_PATH
        )

        if not isinstance(
            current,
            dict,
        ):
            current={}


        current.update(
            {
                "state":
                    "stopped",

                "production_delete":
                    False,

                "delete_performed":
                    False,

                "stopped_at":
                    now_iso(),

                "updated_at":
                    now_iso(),
            }
        )


        atomic_json(
            STATUS_PATH,
            current,
        )

        return 0


    finally:
        os.close(fd)


if __name__=="__main__":
    raise SystemExit(
        main()
    )
