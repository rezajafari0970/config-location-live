from __future__ import annotations

import json
import subprocess
import time

from datetime import datetime, timezone
from pathlib import Path
from typing import Any


STATE = Path(
    "/var/lib/config-location/"
    "health-lifecycle"
)

POLICY_PATH = (
    STATE / "policy-latest.json"
)

TRACKER_PATH = (
    STATE / "consecutive-state.json"
)

SYNC_PATH = (
    STATE / "sync-status.json"
)

WATCHDOG_PATH = (
    STATE / "watchdog-status.json"
)

SETTINGS_PATH = (
    STATE / "safety-policy.json"
)

SNAPSHOT_PATH = (
    STATE / "safety-latest.json"
)


SERVICES = {
    "panel":
        "config-location-panel.service",

    "fetcher":
        "config-location-fetcher.service",

    "health":
        "config-location-health-adaptive.service",
}


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def read_json(
    path: Path,
) -> dict[str, Any]:

    value = json.loads(
        path.read_text(
            encoding="utf-8"
        )
    )

    if not isinstance(
        value,
        dict,
    ):
        raise ValueError(
            f"expected object: {path}"
        )

    return value


def safe_int(
    value: Any,
) -> int:

    try:
        return int(value)
    except Exception:
        return 0


def file_age(
    path: Path,
) -> float:

    return max(
        0.0,
        time.time()
        - path.stat().st_mtime,
    )


def service_active(
    name: str,
) -> bool:

    result = subprocess.run(
        [
            "systemctl",
            "is-active",
            "--quiet",
            name,
        ],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    return (
        result.returncode == 0
    )


def tracker_records(
    tracker: dict[str, Any],
) -> dict[str, dict[str, Any]]:

    records = tracker.get(
        "records",
        {}
    )

    if not isinstance(
        records,
        dict,
    ):
        return {}

    return {
        str(k): v
        for k, v
        in records.items()
        if isinstance(
            v,
            dict,
        )
    }


def decisions(
    policy: dict[str, Any],
) -> list[dict[str, Any]]:

    value = policy.get(
        "decisions",
        []
    )

    if not isinstance(
        value,
        list,
    ):
        return []

    return [
        x
        for x in value
        if isinstance(
            x,
            dict,
        )
    ]


def build_safety_snapshot(
    *,
    policy: dict[str, Any] | None = None,
    tracker: dict[str, Any] | None = None,
    sync: dict[str, Any] | None = None,
    watchdog: dict[str, Any] | None = None,
    settings: dict[str, Any] | None = None,
    service_states: dict[str, bool] | None = None,
    policy_age_seconds: float | None = None,
    tracker_age_seconds: float | None = None,
) -> dict[str, Any]:

    policy = (
        policy
        if policy is not None
        else read_json(
            POLICY_PATH
        )
    )

    tracker = (
        tracker
        if tracker is not None
        else read_json(
            TRACKER_PATH
        )
    )

    sync = (
        sync
        if sync is not None
        else read_json(
            SYNC_PATH
        )
    )

    watchdog = (
        watchdog
        if watchdog is not None
        else read_json(
            WATCHDOG_PATH
        )
    )

    settings = (
        settings
        if settings is not None
        else read_json(
            SETTINGS_PATH
        )
    )


    if service_states is None:

        service_states = {
            key:
                service_active(
                    service
                )
            for key, service
            in SERVICES.items()
        }


    if policy_age_seconds is None:
        policy_age_seconds = (
            file_age(
                POLICY_PATH
            )
        )


    if tracker_age_seconds is None:
        tracker_age_seconds = (
            file_age(
                TRACKER_PATH
            )
        )


    records = tracker_records(
        tracker
    )

    policy_decisions = decisions(
        policy
    )


    tracked = safe_int(
        policy.get(
            "tracked_count",
            len(records),
        )
    )


    states: dict[str, int] = {}

    shadow_candidate_ids = []


    for item in policy_decisions:

        state = str(
            item.get(
                "policy_state",
                "unknown",
            )
        ).strip().lower()

        states[state] = (
            states.get(
                state,
                0
            )
            + 1
        )


        if (
            state
            == "delete_candidate_shadow"
        ):

            config_id = str(
                item.get(
                    "config_id",
                    ""
                )
            )

            if config_id:
                shadow_candidate_ids.append(
                    config_id
                )


    unhealthy_states = {
        "quarantine",
        "deep_quarantine",
        "delete_candidate_shadow",
        "error_retry",
    }


    unhealthy_total = sum(
        states.get(
            state,
            0,
        )
        for state in unhealthy_states
    )


    unhealthy_ratio = (
        unhealthy_total
        / tracked
        if tracked > 0
        else 1.0
    )


    candidate_ratio = (
        len(
            shadow_candidate_ids
        )
        / tracked
        if tracked > 0
        else 1.0
    )


    min_streak = safe_int(
        settings.get(
            "candidate_min_consecutive_unhealthy",
            8,
        )
    )


    future_eligible = []

    rejected_streak = []


    for config_id in (
        shadow_candidate_ids
    ):

        record = records.get(
            config_id,
            {}
        )


        streak = safe_int(
            record.get(
                "consecutive_unhealthy",
                0,
            )
        )


        healthy_streak = safe_int(
            record.get(
                "consecutive_healthy",
                0,
            )
        )


        if (
            streak >= min_streak
            and healthy_streak == 0
        ):

            future_eligible.append(
                {
                    "config_id":
                        config_id,

                    "consecutive_unhealthy":
                        streak,
                }
            )

        else:

            rejected_streak.append(
                config_id
            )


    sync_state = str(
        sync.get(
            "state",
            "missing",
        )
    )


    watchdog_state = str(
        watchdog.get(
            "evaluation",
            {},
        ).get(
            "state",
            "missing",
        )
    )


    gates: dict[str, dict[str, Any]] = {}


    def gate(
        name: str,
        passed: bool,
        reason: str,
        value: Any = None,
    ) -> None:

        gates[name] = {
            "passed":
                bool(
                    passed
                ),

            "reason":
                reason,

            "value":
                value,
        }


    minimum_population = safe_int(
        settings.get(
            "minimum_tracked_population",
            100,
        )
    )


    gate(
        "minimum_population",
        tracked >= minimum_population,
        "tracked_population",
        tracked,
    )


    global_limit = float(
        settings.get(
            "global_unhealthy_freeze_ratio",
            0.45,
        )
    )


    gate(
        "global_unhealthy_ratio",
        unhealthy_ratio < global_limit,
        "global_circuit_breaker",
        round(
            unhealthy_ratio,
            6,
        ),
    )


    candidate_limit = float(
        settings.get(
            "delete_candidate_freeze_ratio",
            0.35,
        )
    )


    gate(
        "candidate_ratio",
        candidate_ratio < candidate_limit,
        "candidate_burst_breaker",
        round(
            candidate_ratio,
            6,
        ),
    )


    max_policy_age = float(
        settings.get(
            "max_policy_age_seconds",
            90,
        )
    )


    gate(
        "policy_freshness",
        policy_age_seconds
        <= max_policy_age,
        "policy_age",
        round(
            policy_age_seconds,
            3,
        ),
    )


    max_tracker_age = float(
        settings.get(
            "max_tracker_age_seconds",
            90,
        )
    )


    gate(
        "tracker_freshness",
        tracker_age_seconds
        <= max_tracker_age,
        "tracker_age",
        round(
            tracker_age_seconds,
            3,
        ),
    )


    allowed_sync_states = set(
        str(x)
        for x in settings.get(
            "allowed_sync_states",
            [
                "synced",
                "idle",
            ],
        )
    )


    gate(
        "sync_state",
        sync_state
        in allowed_sync_states,
        "lifecycle_sync_state",
        sync_state,
    )


    required_watchdog = str(
        settings.get(
            "required_watchdog_state",
            "healthy",
        )
    )


    gate(
        "watchdog_state",
        watchdog_state
        == required_watchdog,
        "stale_watchdog_state",
        watchdog_state,
    )


    for name in (
        "panel",
        "fetcher",
        "health",
    ):

        required = bool(
            settings.get(
                f"require_{name}_active",
                True,
            )
        )

        passed = (
            bool(
                service_states.get(
                    name,
                    False,
                )
            )
            if required
            else True
        )

        gate(
            f"{name}_service",
            passed,
            f"{name}_service_active",
            service_states.get(
                name,
                False,
            ),
        )


    failed_gates = [
        name
        for name, value
        in gates.items()
        if not value[
            "passed"
        ]
    ]


    global_freeze = bool(
        failed_gates
    )


    configured_delete = bool(
        settings.get(
            "production_delete_enabled",
            False,
        )
    )


    # Hard boundary for HT18.9:
    production_delete_allowed = False


    return {
        "schema_version": 1,

        "generated_at":
            now_iso(),

        "mode":
            "shadow",

        "tracked_count":
            tracked,

        "policy_states":
            states,

        "unhealthy_total":
            unhealthy_total,

        "unhealthy_ratio":
            round(
                unhealthy_ratio,
                6,
            ),

        "delete_candidate_shadow":
            len(
                shadow_candidate_ids
            ),

        "delete_candidate_ratio":
            round(
                candidate_ratio,
                6,
            ),

        "candidate_min_consecutive_unhealthy":
            min_streak,

        "future_enforcement_candidates":
            len(
                future_eligible
            ),

        "future_enforcement_candidate_sample":
            future_eligible[:25],

        "rejected_by_streak":
            len(
                rejected_streak
            ),

        "gates":
            gates,

        "failed_gates":
            failed_gates,

        "global_freeze":
            global_freeze,

        "configured_production_delete":
            configured_delete,

        "production_delete_allowed":
            production_delete_allowed,

        "hard_safety_boundary":
            "HT18.9_SHADOW_ONLY",
    }


def write_snapshot(
    snapshot: dict[str, Any],
) -> None:

    tmp = SNAPSHOT_PATH.with_name(
        "."
        + SNAPSHOT_PATH.name
        + ".tmp"
    )


    tmp.write_text(
        json.dumps(
            snapshot,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


    import os

    os.chown(
        tmp,
        -1,
        SNAPSHOT_PATH.parent.stat().st_gid,
    )

    os.chmod(
        tmp,
        0o640,
    )

    os.replace(
        tmp,
        SNAPSHOT_PATH,
    )


def main() -> int:

    snapshot = (
        build_safety_snapshot()
    )

    write_snapshot(
        snapshot
    )

    print(
        json.dumps(
            snapshot,
            ensure_ascii=False,
            indent=2,
        )
    )

    return 0


if __name__ == "__main__":

    raise SystemExit(
        main()
    )
