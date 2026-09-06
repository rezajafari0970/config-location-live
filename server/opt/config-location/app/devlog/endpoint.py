from __future__ import annotations

import hmac
import os
from collections import deque
from pathlib import Path

from aiohttp import web


LOG_ROOT = Path(
    "/var/log/config-location/chatgpt"
)

CURRENT_LOG = LOG_ROOT / "current.log"

MAX_TAIL = 5000
DEFAULT_TAIL = 800


def _expected_token() -> str:
    return os.environ.get(
        "CONFIGLOC_DEVLOG_TOKEN",
        ""
    ).strip()


def _authorized(
    supplied: str
) -> bool:

    expected = _expected_token()

    if not expected or not supplied:
        return False

    return hmac.compare_digest(
        expected,
        supplied
    )


def _read_tail(
    path: Path,
    lines: int
) -> str:

    if not path.is_file():
        return (
            "[DEVLOG]\n"
            "No log has been written yet.\n"
        )

    try:
        with path.open(
            "r",
            encoding="utf-8",
            errors="replace"
        ) as handle:

            data = deque(
                handle,
                maxlen=lines
            )

        return "".join(data)

    except Exception as exc:
        return (
            "[DEVLOG READ ERROR]\n"
            f"{type(exc).__name__}: {exc}\n"
        )


async def devlog_handler(
    request: web.Request
) -> web.Response:

    token = request.match_info.get(
        "token",
        ""
    )

    if not _authorized(token):
        raise web.HTTPNotFound()

    raw_tail = request.query.get(
        "tail",
        str(DEFAULT_TAIL)
    )

    try:
        tail = int(raw_tail)
    except Exception:
        tail = DEFAULT_TAIL

    tail = max(
        1,
        min(
            tail,
            MAX_TAIL
        )
    )

    text = _read_tail(
        CURRENT_LOG,
        tail
    )

    return web.Response(
        text=text,
        content_type="text/plain",
        charset="utf-8",
        headers={
            "Cache-Control": (
                "no-store, no-cache, "
                "must-revalidate, max-age=0"
            ),
            "Pragma": "no-cache",
            "X-Content-Type-Options": "nosniff",
        },
    )
