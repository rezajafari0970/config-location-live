from __future__ import annotations

from typing import Any

from app.health.storage.json_store import (
    JsonHealthResultStore,
)

from .event_bus import enqueue


def emit_health_country_event(
    result: Any,
) -> dict[str,Any]:

    """
    Health -> Country durable event.

    IMPORTANT:
    Uses Health ResultStore's canonical serializer.
    Country does not maintain a parallel Health schema.

    Called only after result_store.save(result)
    succeeds.

    Any Country/EventBus failure is non-fatal.
    """

    try:

        o=JsonHealthResultStore._result_to_dict(
            result
        )


        cid=str(
            o.get(
                "config_id",
                "",
            )
        ).strip()

        if not cid:

            return {
                "status":
                    "ignored_missing_config"
            }


        state=str(
            o.get(
                "state",
                "",
            )
        ).strip().lower()


        decision=(
            (
                o.get(
                    "metadata"
                )
                or {}
            ).get(
                "health_decision"
            )
            or {}
        )


        real_healthy=(
            state=="healthy"
            and
            o.get(
                "xray_started"
            ) is True
            and
            o.get(
                "download_verified"
            ) is True
            and
            o.get(
                "upload_verified"
            ) is True
            and
            isinstance(
                decision,
                dict,
            )
            and
            decision.get(
                "healthy"
            ) is True
            and
            decision.get(
                "xray_ok"
            ) is True
            and
            decision.get(
                "download_ok"
            ) is True
            and
            decision.get(
                "upload_ok"
            ) is True
        )


        if not real_healthy:

            return {
                "status":
                    "ignored_not_real_healthy"
            }


        generation=str(
            o.get("job_id")
            or
            o.get("finished_at")
            or
            o.get("started_at")
            or ""
        ).strip()


        if not generation:

            return {
                "status":
                    "ignored_missing_generation"
            }


        return enqueue(
            config_id=cid,

            generation=
                generation,

            completed_at=str(
                o.get(
                    "finished_at"
                )
                or generation
            ),

            priority=0,

            metadata={
                "producer":
                    "health-result-store",

                "canonical_serializer":
                    "JsonHealthResultStore._result_to_dict",

                "state":
                    "healthy",

                "xray_started":
                    True,

                "download_verified":
                    True,

                "upload_verified":
                    True,
            },
        )


    except Exception as exc:

        # Strict Health isolation.
        return {
            "status":
                "hook_error",

            "error":(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:500],
        }
