from __future__ import annotations

import json
import os
import tempfile

from datetime import datetime, timezone
from pathlib import Path

from filelock import FileLock


DATA = Path(
    "/var/lib/config-location"
)

RUNTIME = (
    DATA / "runtime"
)

LOCKS = (
    DATA / "locks"
)

RUNTIME.mkdir(
    parents=True,
    exist_ok=True
)

LOCKS.mkdir(
    parents=True,
    exist_ok=True
)


def now_iso():
    return datetime.now(
        timezone.utc
    ).isoformat()


def path_for(
    source_id: str
):
    return (
        RUNTIME
        / f"source-{source_id}.json"
    )


def lock_for(
    source_id: str
):
    return FileLock(
        str(
            LOCKS
            / f"runtime-{source_id}.lock"
        ),
        timeout=10,
    )


def read_runtime(
    source_id: str
):
    path = path_for(
        source_id
    )

    if not path.exists():
        return {}

    try:
        return json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )
    except Exception:
        return {}


def write_runtime(
    source_id: str,
    data: dict
):
    path = path_for(
        source_id
    )

    with lock_for(
        source_id
    ):
        fd, tmp = tempfile.mkstemp(
            dir=str(
                path.parent
            ),
            prefix=f".{path.name}.",
            suffix=".tmp",
        )

        try:
            with os.fdopen(
                fd,
                "w",
                encoding="utf-8"
            ) as f:
                json.dump(
                    data,
                    f,
                    ensure_ascii=False,
                    indent=2,
                )

                f.flush()
                os.fsync(
                    f.fileno()
                )

            os.replace(
                tmp,
                path
            )

        finally:
            if os.path.exists(
                tmp
            ):
                os.unlink(
                    tmp
                )


def update_runtime(
    source_id: str,
    **changes,
):
    data = read_runtime(
        source_id
    )

    data.update(
        changes
    )

    write_runtime(
        source_id,
        data
    )

    return data
