from __future__ import annotations

from datetime import (
    datetime,
    timezone,
)


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def mutation_result(
    operation: str,
    *,
    entity: str,
    entity_id=None,
    status: str = "ok",
    changed: bool = False,
    actor: str = "core",
    reason: str = "",
    data: dict | None = None,
):
    return {
        "ok": True,
        "operation": str(operation),
        "entity": str(entity),
        "entity_id":
            (
                str(entity_id)
                if entity_id is not None
                else None
            ),
        "status": str(status),
        "changed": bool(changed),
        "actor": str(actor),
        "reason": str(reason),
        "data":
            dict(data)
            if isinstance(data, dict)
            else {},
        "timestamp": now_iso(),
        "error": None,
    }


def mutation_error(
    operation: str,
    *,
    entity: str,
    entity_id=None,
    actor: str = "core",
    reason: str = "",
    error: str,
    data: dict | None = None,
):
    return {
        "ok": False,
        "operation": str(operation),
        "entity": str(entity),
        "entity_id":
            (
                str(entity_id)
                if entity_id is not None
                else None
            ),
        "status": "error",
        "changed": False,
        "actor": str(actor),
        "reason": str(reason),
        "data":
            dict(data)
            if isinstance(data, dict)
            else {},
        "timestamp": now_iso(),
        "error": str(error),
    }
