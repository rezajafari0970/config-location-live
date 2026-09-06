from __future__ import annotations

from app.health.lifecycle.safety_gates import (
    build_safety_snapshot,
)


def settings():
    return {
        "candidate_min_consecutive_unhealthy":
            8,

        "minimum_tracked_population":
            2,

        "global_unhealthy_freeze_ratio":
            0.45,

        "delete_candidate_freeze_ratio":
            0.35,

        "max_policy_age_seconds":
            90,

        "max_tracker_age_seconds":
            90,

        "allowed_sync_states":
            [
                "synced",
                "idle",
            ],

        "required_watchdog_state":
            "healthy",

        "production_delete_enabled":
            False,
    }


def base():

    policy = {
        "tracked_count": 10,

        "decisions": [
            {
                "config_id": "a",
                "policy_state":
                    "delete_candidate_shadow",
            },

            {
                "config_id": "b",
                "policy_state":
                    "healthy",
            },

            {
                "config_id": "c",
                "policy_state":
                    "healthy",
            },

            {
                "config_id": "d",
                "policy_state":
                    "healthy",
            },

            {
                "config_id": "e",
                "policy_state":
                    "healthy",
            },

            {
                "config_id": "f",
                "policy_state":
                    "healthy",
            },

            {
                "config_id": "g",
                "policy_state":
                    "healthy",
            },

            {
                "config_id": "h",
                "policy_state":
                    "healthy",
            },

            {
                "config_id": "i",
                "policy_state":
                    "healthy",
            },

            {
                "config_id": "j",
                "policy_state":
                    "healthy",
            },
        ],
    }


    tracker = {
        "records": {
            "a": {
                "consecutive_unhealthy": 9,
                "consecutive_healthy": 0,
            }
        }
    }


    sync = {
        "state": "synced"
    }


    watchdog = {
        "evaluation": {
            "state": "healthy"
        }
    }


    services = {
        "panel": True,
        "fetcher": True,
        "health": True,
    }


    return (
        policy,
        tracker,
        sync,
        watchdog,
        services,
    )


def main() -> int:

    (
        policy,
        tracker,
        sync,
        watchdog,
        services,
    ) = base()


    good = build_safety_snapshot(
        policy=policy,
        tracker=tracker,
        sync=sync,
        watchdog=watchdog,
        settings=settings(),
        service_states=services,
        policy_age_seconds=1,
        tracker_age_seconds=1,
    )


    assert (
        good["global_freeze"]
        is False
    )

    assert (
        good["future_enforcement_candidates"]
        == 1
    )

    assert (
        good["production_delete_allowed"]
        is False
    )


    broken_services = dict(
        services
    )

    broken_services[
        "health"
    ] = False


    freeze = build_safety_snapshot(
        policy=policy,
        tracker=tracker,
        sync=sync,
        watchdog=watchdog,
        settings=settings(),
        service_states=
            broken_services,
        policy_age_seconds=1,
        tracker_age_seconds=1,
    )


    assert (
        freeze["global_freeze"]
        is True
    )


    stale = build_safety_snapshot(
        policy=policy,
        tracker=tracker,
        sync=sync,
        watchdog=watchdog,
        settings=settings(),
        service_states=services,
        policy_age_seconds=200,
        tracker_age_seconds=1,
    )


    assert (
        stale["global_freeze"]
        is True
    )


    print(
        "[PASS] Healthy environment permits shadow candidate"
    )

    print(
        "[PASS] Failed Health service freezes enforcement"
    )

    print(
        "[PASS] Stale Policy freezes enforcement"
    )

    print(
        "[PASS] Production delete remains impossible"
    )

    return 0


if __name__ == "__main__":

    raise SystemExit(
        main()
    )
