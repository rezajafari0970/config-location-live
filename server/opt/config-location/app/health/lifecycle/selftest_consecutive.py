from __future__ import annotations

from .consecutive import (
    apply_result,
)


def result(
    *,
    state: str,
    finished: str,
):

    return {
        "config_id":
            "cfg-test",

        "state":
            state,

        "finished_at":
            finished,
    }


def main() -> int:

    record = None


    record, changed = apply_result(
        record,
        result(
            state="healthy",
            finished="2026-01-01T00:00:01Z",
        ),
    )

    assert changed is True
    assert record[
        "consecutive_healthy"
    ] == 1

    assert record[
        "consecutive_unhealthy"
    ] == 0


    # Same exact result must be idempotent.
    same, changed = apply_result(
        record,
        result(
            state="healthy",
            finished="2026-01-01T00:00:01Z",
        ),
    )

    assert changed is False
    assert same[
        "consecutive_healthy"
    ] == 1


    record, changed = apply_result(
        record,
        result(
            state="healthy",
            finished="2026-01-01T00:00:02Z",
        ),
    )

    assert changed is True
    assert record[
        "consecutive_healthy"
    ] == 2


    record, _ = apply_result(
        record,
        result(
            state="unhealthy",
            finished="2026-01-01T00:00:03Z",
        ),
    )

    assert record[
        "consecutive_healthy"
    ] == 0

    assert record[
        "consecutive_unhealthy"
    ] == 1

    assert (
        record[
            "quarantine_started_at"
        ]
        == "2026-01-01T00:00:03Z"
    )


    record, _ = apply_result(
        record,
        result(
            state="unhealthy",
            finished="2026-01-01T00:00:04Z",
        ),
    )

    assert record[
        "consecutive_unhealthy"
    ] == 2


    # ERROR must NOT become third unhealthy.
    record, _ = apply_result(
        record,
        result(
            state="error",
            finished="2026-01-01T00:00:05Z",
        ),
    )

    assert record[
        "consecutive_unhealthy"
    ] == 0

    assert record[
        "consecutive_error"
    ] == 1


    record, _ = apply_result(
        record,
        result(
            state="healthy",
            finished="2026-01-01T00:00:06Z",
        ),
    )

    assert record[
        "consecutive_healthy"
    ] == 1

    assert record[
        "consecutive_unhealthy"
    ] == 0

    assert record[
        "consecutive_error"
    ] == 0

    assert (
        record[
            "quarantine_started_at"
        ]
        is None
    )


    print(
        "[PASS] same result is idempotent"
    )

    print(
        "[PASS] healthy streak increments"
    )

    print(
        "[PASS] unhealthy streak increments"
    )

    print(
        "[PASS] error never extends unhealthy streak"
    )

    print(
        "[PASS] recovery clears quarantine"
    )

    print(
        "[PASS] HT18.1 consecutive tracking"
    )

    return 0


if __name__ == "__main__":

    raise SystemExit(
        main()
    )
