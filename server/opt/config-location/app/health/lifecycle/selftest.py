from __future__ import annotations

from .engine import (
    LifecycleState,
    decide_lifecycle,
)


def main() -> int:

    base = {
        "id": "cfg-1",
        "type": "vless",
        "source_ids": [
            "source-a",
        ],
        "last_seen_at":
            "2026-01-01T00:00:00+00:00",
    }


    new = decide_lifecycle(
        config=base,
        health=None,
        config_id="cfg-1",
    )

    assert (
        new.lifecycle_state
        == LifecycleState.NEW
    )

    assert (
        new.publish_eligible
        is False
    )

    assert (
        new.retest_required
        is True
    )


    healthy = decide_lifecycle(
        config=base,
        health={
            "state": "healthy",
            "finished_at":
                "2026-01-01T00:00:01Z",
        },
        config_id="cfg-1",
    )

    assert (
        healthy.lifecycle_state
        == LifecycleState.HEALTHY
    )

    assert (
        healthy.publish_eligible
        is True
    )

    assert (
        healthy.delete_eligible
        is False
    )


    bad = decide_lifecycle(
        config=base,
        health={
            "state": "unhealthy",
            "finished_at":
                "2026-01-01T00:00:01Z",
        },
        config_id="cfg-1",
    )

    assert (
        bad.lifecycle_state
        == LifecycleState.QUARANTINED
    )

    assert (
        bad.publish_eligible
        is False
    )

    assert (
        bad.delete_eligible
        is False
    )

    assert (
        bad.retest_required
        is True
    )


    error = decide_lifecycle(
        config=base,
        health={
            "state": "error",
            "error_code":
                "runtime_port_conflict",
        },
        config_id="cfg-1",
    )

    assert (
        error.lifecycle_state
        == LifecycleState.ERROR_RETRY
    )

    assert (
        error.delete_eligible
        is False
    )


    missing = decide_lifecycle(
        config=None,
        health={
            "state": "healthy",
            "config_type": "vless",
        },
        config_id="gone",
    )

    assert (
        missing.lifecycle_state
        == LifecycleState.MISSING_CONFIG
    )


    print(
        "[PASS] NEW -> retest"
    )

    print(
        "[PASS] HEALTHY -> publish eligible"
    )

    print(
        "[PASS] UNHEALTHY -> quarantine only"
    )

    print(
        "[PASS] ERROR -> retry, never delete"
    )

    print(
        "[PASS] missing config isolated"
    )

    print(
        "[PASS] HT18 lifecycle foundation"
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(
        main()
    )
