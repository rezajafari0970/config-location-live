from __future__ import annotations

from typing import Any
from pathlib import Path
import json
import os
import time

from app.health.storage.json_store import (
    JsonHealthResultStore,
)

from .event_bus import enqueue


_METRICS=Path(
    "/var/lib/config-location/country/"
    "event-bus/producer-metrics.jsonl"
)


def _metric(
    *,
    config_id: str,
    generation: str,
    status: str,
    detail: dict[str,Any] | None=None,
) -> None:

    try:
        _METRICS.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        row={
            "ts_ns":time.time_ns(),
            "config_id":config_id,
            "generation":generation,
            "status":status,
        }

        if detail:
            row["detail"]=detail

        line=(
            json.dumps(
                row,
                ensure_ascii=False,
                sort_keys=True,
            )
            +"\n"
        )

        fd=os.open(
            _METRICS,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_APPEND,
            0o600,
        )

        try:
            os.write(
                fd,
                line.encode(),
            )
        finally:
            os.close(fd)

    except Exception:
        pass


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


        response=enqueue(
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

                # K2 Same-Runtime Handoff.
                # Consumer can reuse Exit-IP without
                # launching Xray or probing exit again.
                "same_runtime_country":
                    (
                        (
                            o.get("metadata")
                            or {}
                        ).get(
                            "same_runtime_country"
                        )
                    ),
            },
        )

        _metric(
            config_id=cid,
            generation=generation,
            status=str(
                response.get(
                    "status",
                    "unknown",
                )
            ),
            detail=response,
        )

        return response


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
