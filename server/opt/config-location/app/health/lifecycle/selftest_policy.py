from __future__ import annotations

from .policy import (
    PolicyConfig,
    PolicyState,
    decide_policy,
)


def rec(
    *,
    state: str,
    h: int = 0,
    u: int = 0,
    e: int = 0,
    had_unhealthy: bool = False,
    had_error: bool = False,
):

    return {
        "config_id":
            "cfg-test",

        "last_result_state":
            state,

        "consecutive_healthy":
            h,

        "consecutive_unhealthy":
            u,

        "consecutive_error":
            e,

        "last_result_finished_at":
            "2026-01-01T00:00:00Z",

        "last_healthy_at":
            (
                "2026-01-01T00:00:00Z"
                if h > 0
                else None
            ),

        "last_unhealthy_at":
            (
                "2025-12-31T23:59:00Z"
                if had_unhealthy
                else None
            ),

        "last_error_at":
            (
                "2025-12-31T23:59:30Z"
                if had_error
                else None
            ),

        "quarantine_started_at":
            (
                "2026-01-01T00:00:00Z"
                if u > 0
                else None
            ),
    }


def main() -> int:

    cfg = PolicyConfig(
        deep_quarantine_after_unhealthy=2,
        delete_candidate_after_unhealthy=4,
    )


    healthy = decide_policy(
        rec(
            state="healthy",
            h=1,
        ),
        config=cfg,
    )

    assert (
        healthy.policy_state
        == PolicyState.HEALTHY
    )

    assert (
        healthy.publish_eligible
        is True
    )


    recovered = decide_policy(
        rec(
            state="healthy",
            h=1,
            had_unhealthy=True,
        ),
        config=cfg,
    )

    assert (
        recovered.policy_state
        == PolicyState.RECOVERED
    )

    assert (
        recovered.publish_eligible
        is True
    )


    q1 = decide_policy(
        rec(
            state="unhealthy",
            u=1,
        ),
        config=cfg,
    )

    assert (
        q1.policy_state
        == PolicyState.QUARANTINE
    )


    q2 = decide_policy(
        rec(
            state="unhealthy",
            u=2,
        ),
        config=cfg,
    )

    assert (
        q2.policy_state
        == PolicyState.DEEP_QUARANTINE
    )


    q4 = decide_policy(
        rec(
            state="unhealthy",
            u=4,
        ),
        config=cfg,
    )

    assert (
        q4.policy_state
        == PolicyState.DELETE_CANDIDATE_SHADOW
    )

    assert (
        q4.delete_candidate_shadow
        is True
    )

    assert (
        q4.production_delete_allowed
        is False
    )


    err = decide_policy(
        rec(
            state="error",
            e=99,
        ),
        config=cfg,
    )

    assert (
        err.policy_state
        == PolicyState.ERROR_RETRY
    )

    assert (
        err.delete_candidate_shadow
        is False
    )

    assert (
        err.production_delete_allowed
        is False
    )


    print(
        "[PASS] healthy publishes"
    )

    print(
        "[PASS] recovered publishes immediately"
    )

    print(
        "[PASS] 1 unhealthy -> quarantine"
    )

    print(
        "[PASS] 2 unhealthy -> deep quarantine"
    )

    print(
        "[PASS] 4 unhealthy -> shadow delete candidate"
    )

    print(
        "[PASS] error never becomes delete candidate"
    )

    print(
        "[PASS] production deletion remains disabled"
    )

    return 0


if __name__ == "__main__":

    raise SystemExit(
        main()
    )
