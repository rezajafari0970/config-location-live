from __future__ import annotations

import json
import os
import time
import uuid

from datetime import (
    datetime,
    timezone,
)

from pathlib import Path

from filelock import FileLock

from .storage import (
    atomic_write_json,
)


EVENT_ROOT = Path(
    "/var/lib/config-location/events/core"
)

EVENT_LOCK = Path(
    "/var/lib/config-location/locks/"
    "core-events.lock"
)


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def _event_path(
    event_id: str,
):
    return (
        EVENT_ROOT
        / f"{event_id}.json"
    )


def emit_event(
    event_type: str,
    *,
    entity: str = "core",
    entity_id: str | None = None,
    severity: str = "info",
    actor: str = "core",
    message: str = "",
    data: dict | None = None,
):
    """
    Durable append-only Core event.

    Each event is its own atomically written JSON file.
    This avoids shared JSON-array rewrite races.
    """

    event_type = str(
        event_type or ""
    ).strip()

    if not event_type:
        raise ValueError(
            "event_type_required"
        )


    severity = str(
        severity or "info"
    ).lower()


    if severity not in {
        "debug",
        "info",
        "warning",
        "error",
        "critical",
    }:
        raise ValueError(
            "invalid_event_severity"
        )


    EVENT_ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )

    EVENT_LOCK.parent.mkdir(
        parents=True,
        exist_ok=True,
    )


    event_id = (
        f"{time.time_ns()}-"
        f"{os.getpid()}-"
        f"{uuid.uuid4().hex}"
    )


    event = {
        "event_id": event_id,
        "event_type": event_type,
        "entity": str(
            entity or "core"
        ),
        "entity_id":
            (
                str(entity_id)
                if entity_id is not None
                else None
            ),
        "severity": severity,
        "actor": str(
            actor or "core"
        ),
        "message": str(
            message or ""
        ),
        "created_at": now_iso(),
        "data":
            dict(data)
            if isinstance(data, dict)
            else {},
    }


    with FileLock(
        str(EVENT_LOCK),
        timeout=15,
    ):

        atomic_write_json(
            _event_path(
                event_id
            ),
            event,
        )


    return event


def safe_emit_event(
    *args,
    **kwargs,
):
    """
    Observability must not corrupt or partially apply a
    successful Core mutation.

    Event failure therefore returns None instead of
    reversing an already committed safe mutation.
    """

    try:

        return emit_event(
            *args,
            **kwargs,
        )

    except Exception:

        return None


def list_events(
    *,
    limit: int = 50,
    event_type: str | None = None,
    severity: str | None = None,
):
    limit = max(
        1,
        min(
            int(limit),
            500,
        ),
    )

    if not EVENT_ROOT.exists():
        return []


    result = []


    paths = sorted(
        EVENT_ROOT.glob(
            "*.json"
        ),
        key=lambda path:
            path.name,
        reverse=True,
    )


    for path in paths:

        try:

            obj = json.loads(
                path.read_text(
                    encoding="utf-8"
                )
            )

        except Exception:
            continue


        if not isinstance(
            obj,
            dict
        ):
            continue


        if (
            event_type is not None
            and obj.get(
                "event_type"
            ) != event_type
        ):
            continue


        if (
            severity is not None
            and obj.get(
                "severity"
            ) != severity
        ):
            continue


        result.append(
            obj
        )


        if len(
            result
        ) >= limit:
            break


    return result


def event_stats():
    result = {
        "total": 0,
        "severity": {},
        "types": {},
    }

    if not EVENT_ROOT.exists():
        return result


    for path in EVENT_ROOT.glob(
        "*.json"
    ):

        try:

            obj = json.loads(
                path.read_text(
                    encoding="utf-8"
                )
            )

        except Exception:
            continue


        if not isinstance(
            obj,
            dict
        ):
            continue


        result[
            "total"
        ] += 1


        severity = str(
            obj.get(
                "severity",
                "unknown",
            )
        )

        event_type = str(
            obj.get(
                "event_type",
                "unknown",
            )
        )


        result[
            "severity"
        ][severity] = (
            result[
                "severity"
            ].get(
                severity,
                0,
            )
            + 1
        )


        result[
            "types"
        ][event_type] = (
            result[
                "types"
            ].get(
                event_type,
                0,
            )
            + 1
        )


    return result
