from __future__ import annotations

import threading
import time

from typing import Any

from app.country.projection import (
    build_projection,
)


_CACHE_TTL_SECONDS = 2.0

_lock = threading.RLock()

_cache: dict[str, Any] | None = None
_deadline = 0.0


def _projection_cache() -> dict[str, Any]:

    global _cache
    global _deadline

    now = time.monotonic()

    with _lock:

        if (
            _cache is not None
            and now < _deadline
        ):
            return _cache


    value = build_projection()


    with _lock:

        _cache = value

        _deadline = (
            time.monotonic()
            + _CACHE_TTL_SECONDS
        )


    return value


def refresh_projection_cache() -> None:

    global _cache
    global _deadline

    with _lock:

        _cache = None
        _deadline = 0.0


def country_projection_for(
    config_id: str,
) -> dict[str, Any]:

    row = (
        _projection_cache()
        .get(
            "records",
            {},
        )
        .get(
            str(config_id)
        )
    )

    if not isinstance(
        row,
        dict,
    ):

        return {
            "state":
                "unknown",

            "country_code":
                None,

            "country_name":
                None,

            "flag":
                None,

            "confidence":
                None,

            "selected_source":
                None,
        }

    return row


def overlay_country(
    row: dict[str, Any],
) -> dict[str, Any]:

    if not isinstance(
        row,
        dict,
    ):
        return row

    cid = (
        row.get("config_id")
        or row.get("id")
    )

    if not cid:
        return row


    projected = (
        country_projection_for(
            str(cid)
        )
    )


    out = dict(row)

    state = projected.get(
        "state",
        "unknown",
    )

    out[
        "country_state"
    ] = state


    if state == "resolved":

        out[
            "country_code"
        ] = projected.get(
            "country_code"
        )

        out[
            "country_name"
        ] = projected.get(
            "country_name"
        )

        out[
            "country"
        ] = (
            projected.get(
                "country_name"
            )
            or projected.get(
                "country_code"
            )
        )

        out[
            "flag"
        ] = projected.get(
            "flag"
        )

        out[
            "country_confidence"
        ] = projected.get(
            "confidence"
        )

        out[
            "country_source"
        ] = projected.get(
            "selected_source"
        )

    else:

        out["country_code"] = None
        out["country_name"] = None
        out["country"] = None
        out["flag"] = None
        out["country_confidence"] = None
        out["country_source"] = None


    return out


def overlay_country_collection(
    value: Any,
) -> Any:

    if isinstance(
        value,
        list,
    ):

        return [
            (
                overlay_country(item)
                if isinstance(item, dict)
                else item
            )
            for item in value
        ]


    if (
        isinstance(value, dict)
        and (
            "config_id" in value
            or "id" in value
        )
    ):

        return overlay_country(
            value
        )


    return value
