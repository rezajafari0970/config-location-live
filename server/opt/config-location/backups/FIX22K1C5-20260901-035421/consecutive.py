from __future__ import annotations

import hashlib
import json
import os
import tempfile

from copy import deepcopy
from datetime import (
    datetime,
    timezone,
)
from pathlib import Path
from typing import Any

from app.health.lifecycle.write_control import (
    atomic_json_if_changed,
)


RESULT_DIR = Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

CONFIG_DIR = Path(
    "/var/lib/config-location/"
    "configs"
)

STATE_ROOT = Path(
    "/var/lib/config-location/"
    "health-lifecycle"
)

TRACKER_PATH = (
    STATE_ROOT
    / "consecutive-state.json"
)


def now_iso() -> str:

    return datetime.now(
        timezone.utc
    ).isoformat()


def _read_json(
    path: Path,
) -> dict[str, Any] | None:

    try:

        value = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

        if isinstance(
            value,
            dict,
        ):
            return value

    except Exception:
        pass

    return None


def _atomic_json(
    path: Path,
    value: dict[str, Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd, tmp = tempfile.mkstemp(
        dir=str(
            path.parent
        ),
        prefix="."
        + path.name
        + ".",
        suffix=".tmp",
    )

    try:

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as f:

            json.dump(
                value,
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

        # Preserve the destination directory group.
        # This keeps lifecycle state readable by
        # the Panel group after every atomic replace.
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

    finally:

        if os.path.exists(
            tmp
        ):
            os.unlink(
                tmp
            )


def result_fingerprint(
    result: dict[str, Any],
) -> str:
    """
    Stable identity for one Health Result.

    IMPORTANT:
    Re-processing the same latest result must not
    increment streak counters.
    """

    identity = {
        "config_id":
            result.get(
                "config_id"
            ),

        "state":
            result.get(
                "state"
            ),

        "started_at":
            result.get(
                "started_at"
            ),

        "finished_at":
            result.get(
                "finished_at"
            ),

        "error_code":
            result.get(
                "error_code"
            ),

        "decision":
            result.get(
                "decision"
            ),

        "health_qualified":
            result.get(
                "health_qualified"
            ),
    }

    payload = json.dumps(
        identity,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        default=str,
    )

    return hashlib.sha256(
        payload.encode(
            "utf-8"
        )
    ).hexdigest()


def empty_record(
    config_id: str,
) -> dict[str, Any]:

    return {
        "config_id":
            config_id,

        "consecutive_healthy":
            0,

        "consecutive_unhealthy":
            0,

        "consecutive_error":
            0,

        "total_health_results_seen":
            0,

        "last_result_state":
            None,

        "last_result_finished_at":
            None,

        "last_result_fingerprint":
            None,

        "last_healthy_at":
            None,

        "last_unhealthy_at":
            None,

        "last_error_at":
            None,

        "quarantine_started_at":
            None,

        "first_tracked_at":
            now_iso(),

        "updated_at":
            now_iso(),
    }


def apply_result(
    previous: dict[str, Any] | None,
    result: dict[str, Any],
) -> tuple[
    dict[str, Any],
    bool,
]:

    config_id = str(
        result.get(
            "config_id",
            "",
        )
    )

    if not config_id:

        raise ValueError(
            "health result missing config_id"
        )


    record = deepcopy(
        previous
        or empty_record(
            config_id
        )
    )


    fingerprint = (
        result_fingerprint(
            result
        )
    )


    if (
        record.get(
            "last_result_fingerprint"
        )
        == fingerprint
    ):

        return record, False


    state = str(
        result.get(
            "state",
            "",
        )
    ).strip().lower()


    finished_at = (
        result.get(
            "finished_at"
        )
        or now_iso()
    )


    record[
        "total_health_results_seen"
    ] = (
        int(
            record.get(
                "total_health_results_seen",
                0,
            )
        )
        + 1
    )


    if state == "healthy":

        record[
            "consecutive_healthy"
        ] = (
            int(
                record.get(
                    "consecutive_healthy",
                    0,
                )
            )
            + 1
        )

        record[
            "consecutive_unhealthy"
        ] = 0

        record[
            "consecutive_error"
        ] = 0

        record[
            "last_healthy_at"
        ] = finished_at

        record[
            "quarantine_started_at"
        ] = None


    elif state == "unhealthy":

        previous_unhealthy = int(
            record.get(
                "consecutive_unhealthy",
                0,
            )
        )

        record[
            "consecutive_unhealthy"
        ] = (
            previous_unhealthy
            + 1
        )

        record[
            "consecutive_healthy"
        ] = 0

        record[
            "consecutive_error"
        ] = 0

        record[
            "last_unhealthy_at"
        ] = finished_at


        if (
            previous_unhealthy == 0
            or not record.get(
                "quarantine_started_at"
            )
        ):

            record[
                "quarantine_started_at"
            ] = finished_at


    elif state == "error":

        record[
            "consecutive_error"
        ] = (
            int(
                record.get(
                    "consecutive_error",
                    0,
                )
            )
            + 1
        )

        record[
            "consecutive_healthy"
        ] = 0

        # IMPORTANT:
        # Runtime/infra errors do NOT increase
        # consecutive_unhealthy.
        record[
            "consecutive_unhealthy"
        ] = 0

        record[
            "last_error_at"
        ] = finished_at

        record[
            "quarantine_started_at"
        ] = None


    else:

        # Unknown result states behave like an
        # operational error, never a confirmed
        # unhealthy result.

        state = (
            state
            or "unknown"
        )

        record[
            "consecutive_error"
        ] = (
            int(
                record.get(
                    "consecutive_error",
                    0,
                )
            )
            + 1
        )

        record[
            "consecutive_healthy"
        ] = 0

        record[
            "consecutive_unhealthy"
        ] = 0

        record[
            "last_error_at"
        ] = finished_at

        record[
            "quarantine_started_at"
        ] = None


    record[
        "last_result_state"
    ] = state

    record[
        "last_result_finished_at"
    ] = finished_at

    record[
        "last_result_fingerprint"
    ] = fingerprint

    record[
        "updated_at"
    ] = now_iso()


    return record, True


def load_tracker() -> dict[str, Any]:

    value = _read_json(
        TRACKER_PATH
    )

    if not value:

        return {
            "schema_version":
                1,

            "mode":
                "shadow",

            "production_mutation":
                False,

            "generated_at":
                now_iso(),

            "records":
                {},
        }


    records = value.get(
        "records"
    )

    if not isinstance(
        records,
        dict,
    ):

        value[
            "records"
        ] = {}


    return value


def load_latest_results() -> dict[
    str,
    dict[str, Any],
]:

    results = {}

    for path in RESULT_DIR.glob(
        "*.json"
    ):

        obj = _read_json(
            path
        )

        if not obj:
            continue


        config_id = str(
            obj.get(
                "config_id"
            )
            or path.stem
        )


        if not config_id:
            continue


        obj[
            "config_id"
        ] = config_id

        results[
            config_id
        ] = obj


    return results


def update_tracker() -> dict[str, Any]:

    state = load_tracker()

    records = state[
        "records"
    ]

    latest = load_latest_results()

    current_config_ids = {
        path.stem
        for path in CONFIG_DIR.glob(
            "*.json"
        )
    }

    stale_record_ids = [
        config_id
        for config_id in records
        if config_id
        not in current_config_ids
    ]

    for config_id in stale_record_ids:
        records.pop(
            config_id,
            None,
        )

    latest = {
        config_id: result
        for config_id, result
        in latest.items()
        if config_id
        in current_config_ids
    }

    processed_new_results = 0
    unchanged_results = 0


    for config_id, result in (
        latest.items()
    ):

        previous = records.get(
            config_id
        )


        updated, changed = (
            apply_result(
                previous,
                result,
            )
        )


        records[
            config_id
        ] = updated


        if changed:
            processed_new_results += 1
        else:
            unchanged_results += 1


    state[
        "schema_version"
    ] = 1

    state[
        "mode"
    ] = "shadow"

    state[
        "production_mutation"
    ] = False

    state[
        "generated_at"
    ] = now_iso()

    state[
        "latest_result_count"
    ] = len(
        latest
    )

    state[
        "tracked_count"
    ] = len(
        records
    )

    state[
        "tracker_gc_removed"
    ] = len(
        stale_record_ids
    )

    state[
        "current_config_count"
    ] = len(
        current_config_ids
    )

    state[
        "processed_new_results"
    ] = processed_new_results

    state[
        "unchanged_results"
    ] = unchanged_results


    write_performed = atomic_json_if_changed(
        TRACKER_PATH,
        state,
    )

    state[
        "write_performed"
    ] = write_performed


    return state
