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


def refresh_country_projection() -> dict[str, Any]:

    global _cache
    global _deadline

    value = build_projection()

    with _lock:

        _cache = value

        _deadline = (
            time.monotonic()
            + _CACHE_TTL_SECONDS
        )

    return value


def get_country_projection() -> dict[str, Any]:

    global _cache
    global _deadline

    now = time.monotonic()

    with _lock:

        if (
            _cache is not None
            and now < _deadline
        ):
            return _cache


    return refresh_country_projection()


def invalidate_country_projection() -> None:

    global _cache
    global _deadline

    with _lock:

        _cache = None
        _deadline = 0.0


def country_record_for(
    config_id: str,
) -> dict[str, Any] | None:

    row = (
        get_country_projection()
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
        return None

    return row


def country_state_for(
    config_id: str,
) -> str:

    row = country_record_for(
        config_id
    )

    if not row:
        return "unknown"

    return str(
        row.get(
            "state",
            "unknown",
        )
    )


def country_code_for_config(
    config_id: str,
) -> str | None:

    row = country_record_for(
        config_id
    )

    if not row:
        return None

    if row.get("state") != "resolved":
        return None

    code = row.get(
        "country_code"
    )

    if (
        isinstance(code, str)
        and len(code.strip()) == 2
        and code.strip().isalpha()
    ):

        return code.strip().upper()

    return None


def discovered_country_codes() -> set[str]:

    projection = get_country_projection()

    result: set[str] = set()

    for row in (
        projection
        .get(
            "records",
            {},
        )
        .values()
    ):

        if not isinstance(
            row,
            dict,
        ):
            continue

        if row.get("state") != "resolved":
            continue

        code = row.get(
            "country_code"
        )

        if (
            isinstance(code, str)
            and len(code.strip()) == 2
            and code.strip().isalpha()
        ):

            result.add(
                code.strip().upper()
            )

    return result
