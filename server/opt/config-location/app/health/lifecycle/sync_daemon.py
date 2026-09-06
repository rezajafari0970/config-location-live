from __future__ import annotations

import fcntl
import json
import os
import signal
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from app.health.lifecycle.write_control import (
    HeartbeatGate,
    atomic_json_if_changed,
)

from app.health.lifecycle.consecutive import (
    update_tracker,
)
from app.health.lifecycle.policy import (
    build_policy_snapshot,
)


RESULT_DIR = Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

STATE_DIR = Path(
    "/var/lib/config-location/"
    "health-lifecycle"
)

STATUS_PATH = (
    STATE_DIR
    / "sync-status.json"
)

LOCK_PATH = (
    STATE_DIR
    / "sync.lock"
)


MIN_SLEEP = 2.0
MAX_SLEEP = 15.0

MAX_STALE_SECONDS = 60.0
ERROR_BACKOFF_MIN = 5.0
ERROR_BACKOFF_MAX = 30.0

STATUS_HEARTBEAT_SECONDS = 30.0

_shutdown = False


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def atomic_json(
    path: Path,
    payload: dict,
) -> None:

    tmp = path.with_name(
        "."
        + path.name
        + ".tmp"
    )

    with tmp.open(
        "w",
        encoding="utf-8",
    ) as f:

        json.dump(
            payload,
            f,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )

        f.write("\n")

        f.flush()
        os.fsync(
            f.fileno()
        )

    # Preserve destination directory group.
    parent_gid = path.parent.stat().st_gid

    os.chown(
        tmp,
        -1,
        parent_gid,
    )

    os.chmod(
        tmp,
        0o640,
    )

    os.replace(
        tmp,
        path,
    )


def result_signature() -> tuple[int, int]:

    count = 0
    newest_ns = 0

    for path in RESULT_DIR.glob(
        "*.json"
    ):

        try:
            stat = path.stat()
        except FileNotFoundError:
            continue

        count += 1

        newest_ns = max(
            newest_ns,
            stat.st_mtime_ns,
        )

    return (
        count,
        newest_ns,
    )


def handle_signal(
    signum,
    frame,
):
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


_status_gate = HeartbeatGate(
    heartbeat_seconds=
        STATUS_HEARTBEAT_SECONDS,
)


def write_status(
    **kwargs,
) -> None:

    semantic = {
        key: value
        for key, value
        in kwargs.items()
        if key not in {
            "cycle",
            "sleep_seconds",
        }
    }

    should_write, reason = (
        _status_gate.should_write(
            semantic
        )
    )

    if not should_write:
        return


    base = {
        "schema_version": 1,
        "component":
            "lifecycle-sync",
        "updated_at":
            now_iso(),
        "pid":
            os.getpid(),
        "write_reason":
            reason,
    }

    base.update(
        kwargs
    )

    atomic_json_if_changed(
        STATUS_PATH,
        base,
    )


def main() -> int:

    STATE_DIR.mkdir(
        parents=True,
        exist_ok=True,
    )

    lock_file = LOCK_PATH.open(
        "a+"
    )

    try:
        fcntl.flock(
            lock_file.fileno(),
            fcntl.LOCK_EX
            | fcntl.LOCK_NB,
        )
    except BlockingIOError:
        print(
            "another lifecycle sync "
            "instance is already running",
            file=sys.stderr,
        )
        return 2


    last_signature = None
    sleep_seconds = MIN_SLEEP
    cycle = 0
    sync_count = 0
    error_count = 0
    consecutive_errors = 0
    last_success_monotonic = time.monotonic()


    write_status(
        state="starting",
        cycle=cycle,
        sync_count=sync_count,
        error_count=error_count,
        sleep_seconds=
            sleep_seconds,
    )


    while not _shutdown:

        cycle += 1

        try:

            signature = (
                result_signature()
            )

            changed = (
                signature
                != last_signature
            )


            if changed:

                before = time.monotonic()

                tracker = (
                    update_tracker()
                )

                policy = (
                    build_policy_snapshot()
                )

                elapsed_ms = (
                    time.monotonic()
                    - before
                ) * 1000.0

                sync_count += 1
                consecutive_errors = 0
                last_success_monotonic = time.monotonic()

                last_signature = (
                    signature
                )

                sleep_seconds = (
                    MIN_SLEEP
                )


                write_status(
                    state="synced",
                    cycle=cycle,
                    sync_count=
                        sync_count,
                    error_count=
                        error_count,
                    result_count=
                        signature[0],
                    newest_result_mtime_ns=
                        signature[1],
                    processed_new_results=
                        tracker.get(
                            "processed_new_results",
                            0,
                        ),
                    unchanged_results=
                        tracker.get(
                            "unchanged_results",
                            0,
                        ),
                    tracked_count=
                        tracker.get(
                            "tracked_count",
                            0,
                        ),
                    publish_eligible=
                        policy.get(
                            "publish_eligible",
                            0,
                        ),
                    quarantine_count=
                        policy.get(
                            "quarantine_count",
                            0,
                        ),
                    sync_duration_ms=
                        round(
                            elapsed_ms,
                            3,
                        ),
                    sleep_seconds=
                        sleep_seconds,
                )

            else:

                sleep_seconds = min(
                    MAX_SLEEP,
                    sleep_seconds
                    + 1.0,
                )

                write_status(
                    state="idle",
                    cycle=cycle,
                    sync_count=
                        sync_count,
                    error_count=
                        error_count,
                    result_count=
                        signature[0],
                    newest_result_mtime_ns=
                        signature[1],
                    sleep_seconds=
                        sleep_seconds,
                )


        except Exception as exc:

            error_count += 1
            consecutive_errors += 1

            sleep_seconds = min(
                ERROR_BACKOFF_MAX,
                max(
                    ERROR_BACKOFF_MIN,
                    float(
                        2 ** min(
                            consecutive_errors,
                            4,
                        )
                    ),
                ),
            )

            write_status(
                state="error",
                cycle=cycle,
                sync_count=
                    sync_count,
                error_count=
                    error_count,
                error_type=
                    type(exc).__name__,
                error_message=
                    str(exc)[:1000],
                consecutive_errors=
                    consecutive_errors,
                stale_seconds=
                    round(
                        time.monotonic()
                        - last_success_monotonic,
                        3,
                    ),
                sleep_seconds=
                    sleep_seconds,
            )


        end = (
            time.monotonic()
            + sleep_seconds
        )

        while (
            not _shutdown
            and time.monotonic()
            < end
        ):
            time.sleep(
                min(
                    0.5,
                    end
                    - time.monotonic(),
                )
            )


    write_status(
        state="stopped",
        cycle=cycle,
        sync_count=sync_count,
        error_count=error_count,
        sleep_seconds=
            sleep_seconds,
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(
        main()
    )
