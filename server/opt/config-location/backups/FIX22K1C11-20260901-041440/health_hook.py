from __future__ import annotations

from typing import Any

from .event_bus import enqueue


def _as_dict(
    result: Any,
) -> dict[str,Any]:

    if isinstance(result,dict):
        return result

    if hasattr(
        result,
        "to_dict",
    ):
        value=result.to_dict()

        if isinstance(value,dict):
            return value

    if hasattr(
        result,
        "__dict__",
    ):
        raw=dict(
            result.__dict__
        )

        # Enum -> value
        state=raw.get("state")

        if hasattr(
            state,
            "value",
        ):
            raw["state"]=state.value

        return raw

    return {}


def emit_health_country_event(
    result: Any,
) -> dict[str,Any]:

    """
    Called only AFTER ResultStore.save(result)
    succeeds.

    Country event failures never affect Health.
    """

    try:

        o=_as_dict(result)

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


        state=o.get(
            "state",
            "",
        )

        if hasattr(
            state,
            "value",
        ):
            state=state.value

        state=str(
            state
        ).strip().lower()


        xray=bool(
            o.get(
                "xray_started",
                False,
            )
        )

        download=bool(
            o.get(
                "download_verified",
                False,
            )
        )

        upload=bool(
            o.get(
                "upload_verified",
                False,
            )
        )


        metadata=(
            o.get("metadata")
            or {}
        )

        decision=(
            metadata.get(
                "health_decision"
            )
            or {}
        )


        decision_healthy=bool(
            isinstance(
                decision,
                dict,
            )
            and decision.get(
                "healthy",
                False,
            )
        )


        if not (
            state=="healthy"
            and xray
            and download
            and upload
            and decision_healthy
        ):

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
            generation=generation,
            completed_at=str(
                o.get(
                    "finished_at"
                )
                or generation
            ),
            priority=0,
            metadata={
                "producer":
                    "result-store-save",

                "health_state":
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

        return {
            "status":
                "hook_error",

            "error":(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:500],
        }
