from __future__ import annotations

import tempfile
from pathlib import Path

from .batch import BatchJob
from .scheduler import (
    SchedulerBusy,
    SchedulerLock,
    load_cursor,
    save_cursor,
    select_batch,
)


def main() -> int:

    jobs = [
        BatchJob(
            config_id=f"id-{i}",
            config_type="vless",
            source=f"src-{i}",
        )
        for i in range(5)
    ]

    selected, next_cursor = (
        select_batch(
            jobs,
            cursor=0,
            batch_size=2,
        )
    )

    assert [
        x.config_id
        for x in selected
    ] == [
        "id-0",
        "id-1",
    ]

    assert next_cursor == 2

    print(
        "[PASS] first batch selection"
    )

    selected2, next_cursor2 = (
        select_batch(
            jobs,
            cursor=4,
            batch_size=2,
        )
    )

    assert [
        x.config_id
        for x in selected2
    ] == [
        "id-4",
        "id-0",
    ]

    assert next_cursor2 == 1

    print(
        "[PASS] round-robin wraparound"
    )

    with tempfile.TemporaryDirectory(
        prefix="ht13-"
    ) as td:

        root = Path(td)

        cursor = root / "cursor.json"

        assert load_cursor(cursor) == 0

        save_cursor(
            cursor,
            7,
        )

        assert load_cursor(cursor) == 7

        assert (
            cursor.stat().st_mode
            & 0o777
        ) == 0o600

        print(
            "[PASS] cursor persistence"
        )

        lock_path = (
            root / "scheduler.lock"
        )

        lock1 = SchedulerLock(
            lock_path
        )

        lock1.acquire()

        try:
            lock2 = SchedulerLock(
                lock_path
            )

            try:
                lock2.acquire()
            except SchedulerBusy:
                pass
            else:
                raise AssertionError(
                    "overlap lock failed"
                )

            print(
                "[PASS] overlap protection"
            )

        finally:
            lock1.release()

    print(
        "[PASS] HT13 scheduler foundation"
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
