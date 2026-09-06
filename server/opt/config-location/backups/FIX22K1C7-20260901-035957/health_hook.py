from __future__ import annotations

from typing import Any

from .event_bus import enqueue


def emit_health_country_event(
    result: dict[str,Any],
) -> dict[str,Any]:

    """
    Durable Health -> Country event producer.

    Safety:
      * Health remains authoritative.
      * Country failures are non-fatal.
      * Requires qualified + real upload/download.
      * Country FINAL is suppressed by Event Bus.
    """

    try:

        cid=str(
            result.get(
                "config_id",
                "",
            )
        ).strip()

        if not cid:
            return {
                "status":
                    "ignored_missing_config"
            }


        qualified=bool(
            result.get(
                "health_qualified",
                False,
            )
        )


        decision=(
            result.get("decision")
            or
            (
                result.get("metadata")
                or {}
            ).get(
                "health_decision"
            )
            or {}
        )


        download=bool(
            result.get(
                "download_verified",
                False,
            )
        )

        upload=bool(
            result.get(
                "upload_verified",
                False,
            )
        )


        if isinstance(
            decision,
            dict,
        ):

            download=bool(
                download
                or decision.get(
                    "download_ok",
                    False,
                )
            )

            upload=bool(
                upload
                or decision.get(
                    "upload_ok",
                    False,
                )
            )


        if not (
            qualified
            and download
            and upload
        ):

            return {
                "status":
                    "ignored_not_qualified"
            }


        generation=str(
            result.get(
                "finished_at"
            )
            or
            result.get(
                "started_at"
            )
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
            completed_at=generation,
            priority=0,
            metadata={
                "producer":
                    "health-lifecycle",

                "health_qualified":
                    True,

                "upload_verified":
                    True,

                "download_verified":
                    True,
            },
        )


    except Exception as exc:

        # Country must NEVER change Health outcome.
        return {
            "status":"hook_error",

            "error":(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:500],
        }
