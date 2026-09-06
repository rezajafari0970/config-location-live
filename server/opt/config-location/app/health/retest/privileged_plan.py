from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any

from app.settings.engine import get_settings


LATEST = Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

SCHEDULER_STATE = Path(
    "/var/lib/config-location/"
    "health-scheduler/state.json"
)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_time(
    value: Any,
) -> datetime | None:

    if not isinstance(value, str):
        return None

    value = value.strip()

    if not value:
        return None

    try:
        dt = datetime.fromisoformat(
            value.replace(
                "Z",
                "+00:00",
            )
        )
    except ValueError:
        return None

    if dt.tzinfo is None:
        dt = dt.replace(
            tzinfo=timezone.utc
        )

    return dt.astimezone(
        timezone.utc
    )


def _retest_minutes() -> int:

    settings = get_settings()

    section = settings.get(
        "health_retest",
        {},
    )

    try:
        value = int(
            section.get(
                "retest_minutes",
                5,
            )
        )
    except (
        TypeError,
        ValueError,
    ):
        value = 5

    return max(
        1,
        min(
            value,
            1440,
        ),
    )


def _inflight_ids() -> set[str]:

    result: set[str] = set()

    if not SCHEDULER_STATE.exists():
        return result

    try:
        data = json.loads(
            SCHEDULER_STATE.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        return result

    def walk(value: Any) -> None:

        if isinstance(
            value,
            dict,
        ):
            state = str(
                value.get(
                    "state",
                    "",
                )
            ).lower()

            cid = value.get(
                "config_id"
            )

            if (
                cid
                and state in {
                    "queued",
                    "running",
                    "leased",
                    "in_flight",
                }
            ):
                result.add(
                    str(cid)
                )

            for child in value.values():
                walk(child)

        elif isinstance(
            value,
            list,
        ):
            for child in value:
                walk(child)

    walk(data)

    return result


def _real_healthy(
    data: dict[str, Any],
) -> bool:

    return (
        str(
            data.get(
                "state",
                "",
            )
        ).lower()
        == "healthy"
        and data.get(
            "xray_started"
        )
        is True
        and data.get(
            "download_verified"
        )
        is True
        and data.get(
            "upload_verified"
        )
        is True
    )


def build_privileged_retest_plan(
    *,
    limit: int = 200,
) -> dict[str, Any]:

    now = _now()

    minutes = _retest_minutes()
    interval = minutes * 60

    inflight = _inflight_ids()

    scanned = 0
    parsed = 0
    healthy = 0
    invalid = 0
    not_due = 0
    in_flight = 0

    states: dict[str, int] = {}

    due: list[
        dict[str, Any]
    ] = []

    for path in LATEST.glob(
        "*.json"
    ):

        scanned += 1

        try:
            data = json.loads(
                path.read_text(
                    encoding="utf-8",
                    errors="replace",
                )
            )
        except Exception:
            invalid += 1
            continue

        if not isinstance(
            data,
            dict,
        ):
            invalid += 1
            continue

        parsed += 1

        state = str(
            data.get(
                "state",
                "unknown",
            )
        ).lower()

        states[state] = (
            states.get(
                state,
                0,
            )
            + 1
        )

        if not _real_healthy(
            data
        ):
            continue

        healthy += 1

        cid = str(
            data.get(
                "config_id",
                "",
            )
        ).strip()

        ctype = str(
            data.get(
                "config_type",
                "unknown",
            )
        ).strip().lower()

        finished_raw = data.get(
            "finished_at"
        )

        finished = _parse_time(
            finished_raw
        )

        if (
            not cid
            or finished is None
        ):
            invalid += 1
            continue

        if cid in inflight:
            in_flight += 1
            continue

        age = (
            now - finished
        ).total_seconds()

        if age < interval:
            not_due += 1
            continue

        due.append(
            {
                "config_id":
                    cid,

                "config_type":
                    ctype,

                "state":
                    "healthy",

                "last_finished_at":
                    finished.isoformat(),

                "age_seconds":
                    int(age),

                "due_by_seconds":
                    int(
                        age
                        - interval
                    ),

                "interval_seconds":
                    interval,

                "record_path":
                    str(path),
            }
        )

    due.sort(
        key=lambda row: (
            -row[
                "due_by_seconds"
            ],
            row[
                "config_id"
            ],
        )
    )

    return {
        "mode":
            "privileged_dry_run",

        "generated_at":
            now.isoformat(),

        "canonical_store":
            str(LATEST),

        "retest_minutes":
            minutes,

        "interval_seconds":
            interval,

        "scanned_records":
            scanned,

        "parsed_records":
            parsed,

        "states":
            states,

        "real_healthy":
            healthy,

        "not_due":
            not_due,

        "inflight_ids":
            len(inflight),

        "healthy_inflight":
            in_flight,

        "invalid_records":
            invalid,

        "due_total":
            len(due),

        "candidate_limit":
            limit,

        "candidate_count":
            min(
                len(due),
                limit,
            ),

        "candidates":
            due[:limit],

        "production_execution":
            False,

        "health_state_mutation":
            False,
    }
