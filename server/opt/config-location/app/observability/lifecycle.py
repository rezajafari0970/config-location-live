from __future__ import annotations

import json
import time

from datetime import datetime, timezone
from pathlib import Path
from typing import Any


STATE_ROOT = Path(
    "/var/lib/config-location/"
    "health-lifecycle"
)

TRACKER_PATH = (
    STATE_ROOT
    / "consecutive-state.json"
)

POLICY_PATH = (
    STATE_ROOT
    / "policy-latest.json"
)

SYNC_PATH = (
    STATE_ROOT
    / "sync-status.json"
)

WATCHDOG_PATH = (
    STATE_ROOT
    / "watchdog-status.json"
)


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def read_json(
    path: Path,
) -> dict[str, Any] | None:
    try:
        obj = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

        if isinstance(
            obj,
            dict,
        ):
            return obj

    except Exception:
        pass

    return None


def age_seconds(
    path: Path,
) -> float | None:
    try:
        return round(
            max(
                0.0,
                time.time()
                - path.stat().st_mtime,
            ),
            3,
        )
    except FileNotFoundError:
        return None


def safe_int(
    value: Any,
    default: int = 0,
) -> int:
    try:
        return int(value)
    except Exception:
        return default


def build_lifecycle_observability() -> dict[str, Any]:

    tracker = read_json(
        TRACKER_PATH
    )

    policy = read_json(
        POLICY_PATH
    )

    sync = read_json(
        SYNC_PATH
    )

    watchdog = read_json(
        WATCHDOG_PATH
    )


    tracker_records = (
        tracker.get(
            "records",
            {},
        )
        if tracker
        else {}
    )

    if not isinstance(
        tracker_records,
        dict,
    ):
        tracker_records = {}


    policy_counts = (
        policy.get(
            "counts",
            {},
        )
        if policy
        else {}
    )

    if not isinstance(
        policy_counts,
        dict,
    ):
        policy_counts = {}


    healthy = safe_int(
        policy_counts.get(
            "healthy"
        )
    )

    recovered = safe_int(
        policy_counts.get(
            "recovered"
        )
    )

    quarantine = safe_int(
        policy_counts.get(
            "quarantine"
        )
    )

    deep_quarantine = safe_int(
        policy_counts.get(
            "deep_quarantine"
        )
    )

    error_retry = safe_int(
        policy_counts.get(
            "error_retry"
        )
    )

    unknown = safe_int(
        policy_counts.get(
            "unknown"
        )
    )

    delete_candidate = safe_int(
        policy_counts.get(
            "delete_candidate_shadow"
        )
    )


    sync_state = (
        str(
            sync.get(
                "state",
                "unknown",
            )
        )
        if sync
        else "missing"
    )


    watchdog_eval = (
        watchdog.get(
            "evaluation",
            {},
        )
        if watchdog
        else {}
    )

    if not isinstance(
        watchdog_eval,
        dict,
    ):
        watchdog_eval = {}


    watchdog_state = str(
        watchdog_eval.get(
            "state",
            "missing",
        )
    )

    watchdog_reason = str(
        watchdog_eval.get(
            "reason",
            "unknown",
        )
    )


    policy_available = (
        policy is not None
    )

    tracker_available = (
        tracker is not None
    )

    sync_available = (
        sync is not None
    )

    watchdog_available = (
        watchdog is not None
    )


    freshness = {
        "tracker_seconds":
            age_seconds(
                TRACKER_PATH
            ),

        "policy_seconds":
            age_seconds(
                POLICY_PATH
            ),

        "sync_seconds":
            age_seconds(
                SYNC_PATH
            ),

        "watchdog_seconds":
            age_seconds(
                WATCHDOG_PATH
            ),
    }


    warnings = []


    if not tracker_available:
        warnings.append(
            "tracker_missing"
        )


    if not policy_available:
        warnings.append(
            "policy_missing"
        )


    if not sync_available:
        warnings.append(
            "sync_status_missing"
        )


    if not watchdog_available:
        warnings.append(
            "watchdog_status_missing"
        )


    if sync_state == "error":
        warnings.append(
            "sync_error"
        )


    if watchdog_state in {
        "recover",
        "stale",
    }:
        warnings.append(
            "watchdog_"
            + watchdog_state
        )


    for name, value in (
        freshness.items()
    ):
        if (
            value is not None
            and value > 90.0
        ):
            warnings.append(
                name.replace(
                    "_seconds",
                    "",
                )
                + "_stale"
            )


    state = "healthy"

    if warnings:
        state = "warning"


    if (
        not policy_available
        or not tracker_available
        or sync_state == "error"
        or watchdog_state == "stale"
    ):
        state = "critical"


    return {
        "schema_version": 1,

        "generated_at":
            now_iso(),

        "state":
            state,

        "warnings":
            warnings,

        "tracker": {
            "available":
                tracker_available,

            "tracked_count":
                safe_int(
                    tracker.get(
                        "tracked_count"
                    )
                    if tracker
                    else 0
                ),

            "record_count":
                len(
                    tracker_records
                ),

            "processed_new_results":
                safe_int(
                    tracker.get(
                        "processed_new_results"
                    )
                    if tracker
                    else 0
                ),

            "unchanged_results":
                safe_int(
                    tracker.get(
                        "unchanged_results"
                    )
                    if tracker
                    else 0
                ),
        },

        "policy": {
            "available":
                policy_available,

            "tracked_count":
                safe_int(
                    policy.get(
                        "tracked_count"
                    )
                    if policy
                    else 0
                ),

            "healthy":
                healthy,

            "recovered":
                recovered,

            "quarantine":
                quarantine,

            "deep_quarantine":
                deep_quarantine,

            "error_retry":
                error_retry,

            "unknown":
                unknown,

            "delete_candidate_shadow":
                delete_candidate,

            "publish_eligible":
                safe_int(
                    policy.get(
                        "publish_eligible"
                    )
                    if policy
                    else 0
                ),

            "suppressed":
                (
                    quarantine
                    + deep_quarantine
                    + error_retry
                    + unknown
                    + delete_candidate
                ),

            "production_delete_enabled":
                bool(
                    policy.get(
                        "production_delete_enabled",
                        False,
                    )
                    if policy
                    else False
                ),
        },

        "sync": {
            "available":
                sync_available,

            "state":
                sync_state,

            "cycle":
                safe_int(
                    sync.get(
                        "cycle"
                    )
                    if sync
                    else 0
                ),

            "sync_count":
                safe_int(
                    sync.get(
                        "sync_count"
                    )
                    if sync
                    else 0
                ),

            "error_count":
                safe_int(
                    sync.get(
                        "error_count"
                    )
                    if sync
                    else 0
                ),

            "processed_new_results":
                safe_int(
                    sync.get(
                        "processed_new_results"
                    )
                    if sync
                    else 0
                ),

            "sync_duration_ms":
                sync.get(
                    "sync_duration_ms"
                )
                if sync
                else None,

            "sleep_seconds":
                sync.get(
                    "sleep_seconds"
                )
                if sync
                else None,

            "write_reason":
                sync.get(
                    "write_reason"
                )
                if sync
                else None,
        },

        "watchdog": {
            "available":
                watchdog_available,

            "state":
                watchdog_state,

            "reason":
                watchdog_reason,

            "recovery_count":
                safe_int(
                    watchdog.get(
                        "recovery_count"
                    )
                    if watchdog
                    else 0
                ),

            "restart_failures":
                safe_int(
                    watchdog.get(
                        "restart_failures"
                    )
                    if watchdog
                    else 0
                ),

            "sync_service_active":
                bool(
                    watchdog.get(
                        "sync_service_active",
                        False,
                    )
                    if watchdog
                    else False
                ),

            "write_reason":
                watchdog.get(
                    "write_reason"
                )
                if watchdog
                else None,
        },

        "freshness":
            freshness,

        "safety": {
            "production_delete":
                False,

            "panel_read_only":
                True,

            "lifecycle_mutation_from_panel":
                False,
        },
    }
