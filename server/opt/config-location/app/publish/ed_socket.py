from __future__ import annotations

import json
import os
import re
import tempfile

from pathlib import Path

from aiohttp import web
from filelock import FileLock


PUBLIC = Path(
    "/var/www/config-location-sub/current"
)

CURSORS = Path(
    "/var/lib/config-location/file-publish/cursors"
)

SOCKET = Path(
    "/run/config-location-ed/ed.sock"
)

KEY_RE = re.compile(
    r"^[A-Za-z0-9_-]+$"
)


def _atomic_cursor(
    path: Path,
    value: int,
):

    fd, tmp = tempfile.mkstemp(
        dir=str(path.parent),
        prefix=".cursor.",
        suffix=".tmp",
    )

    try:

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as f:

            f.write(
                str(value)
            )

            f.flush()
            os.fsync(
                f.fileno()
            )

        os.replace(
            tmp,
            path,
        )

    finally:

        if os.path.exists(tmp):
            os.unlink(tmp)


async def select_one(
    request: web.Request,
):

    key = str(
        request.match_info[
            "key"
        ]
    ).lower()

    if not KEY_RE.fullmatch(
        key
    ):
        raise web.HTTPNotFound()

    if (
        request.query.get("ed")
        != "1"
    ):
        raise web.HTTPNotFound()

    index_path = (
        PUBLIC
        / f"{key}.index.json"
    )

    try:

        obj = json.loads(
            index_path.read_text(
                encoding="utf-8"
            )
        )

    except FileNotFoundError:
        raise web.HTTPNotFound()

    except Exception:
        raise web.HTTPServiceUnavailable()

    items = obj.get(
        "items",
        []
    )

    if not isinstance(
        items,
        list,
    ):
        items = []

    items = [
        item
        for item in items
        if isinstance(
            item,
            str,
        )
    ]

    if not items:

        return web.Response(
            text="",
            content_type="text/plain",
            charset="utf-8",
            headers={
                "Cache-Control":
                    "no-store",
                "X-Config-Count":
                    "0",
                "X-Config-ED":
                    "1",
            },
        )

    CURSORS.mkdir(
        parents=True,
        exist_ok=True,
    )

    cursor = (
        CURSORS
        / f"{key}.cursor"
    )

    lock = FileLock(
        str(
            CURSORS
            / f"{key}.lock"
        ),
        timeout=10,
    )

    with lock:

        current = -1

        try:
            current = int(
                cursor.read_text(
                    encoding="utf-8"
                ).strip()
            )
        except Exception:
            pass

        index = (
            current + 1
        ) % len(items)

        _atomic_cursor(
            cursor,
            index,
        )

        raw = items[
            index
        ]

    return web.Response(
        text=raw,
        content_type="text/plain",
        charset="utf-8",
        headers={
            "Cache-Control":
                "no-store",
            "X-Config-Count":
                "1",
            "X-Config-ED":
                "1",
            "X-Config-Key":
                key,
        },
    )


def create_app():

    app = web.Application()

    app.router.add_get(
        "/sub/{key}.txt",
        select_one,
    )

    return app


def main():

    try:
        SOCKET.unlink()
    except FileNotFoundError:
        pass

    web.run_app(
        create_app(),
        path=str(SOCKET),
        print=None,
        access_log=None,
    )


if __name__ == "__main__":
    main()
