from __future__ import annotations

import json
import os
import tempfile

from datetime import datetime, timezone
from pathlib import Path

from filelock import FileLock

from .identifiers import (
    validate_source_id
        as _validate_source_id,
)

from .storage import (
    quarantine_file,
)

from .events import (
    safe_emit_event,
)


DATA = Path(
    "/var/lib/config-location"
)

RUNTIME = (
    DATA / "runtime"
)

LOCKS = (
    DATA / "locks"
)

RUNTIME_QUARANTINE = (
    DATA
    / "quarantine"
    / "source-runtime"
)

RUNTIME.mkdir(
    parents=True,
    exist_ok=True
)

LOCKS.mkdir(
    parents=True,
    exist_ok=True
)

RUNTIME_QUARANTINE.mkdir(
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
    source_id = _validate_source_id(
        source_id
    )

    return (
        RUNTIME
        / f"source-{source_id}.json"
    )


def lock_for(
    source_id: str
):
    source_id = _validate_source_id(
        source_id
    )

    return FileLock(
        str(
            LOCKS
            / f"runtime-{source_id}.lock"
        ),
        timeout=30,
    )


def _read_runtime_unlocked(
    path: Path
):

    if not path.exists():
        return {}


    try:

        obj = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )


        if isinstance(
            obj,
            dict
        ):
            return obj


        reason = (
            "runtime_not_dict"
        )


    except Exception as exc:

        reason = (
            "runtime_json_error:"
            + type(exc).__name__
        )


    # Runtime state is recoverable, but corruption must
    # never be silently indistinguishable from no state.
    try:

        name = path.name

        source_id = (
            name[
                len("source-"):
                -len(".json")
            ]
            if (
                name.startswith(
                    "source-"
                )
                and name.endswith(
                    ".json"
                )
            )
            else None
        )


        target = quarantine_file(
            path,
            RUNTIME_QUARANTINE,
            reason=reason,
            metadata={
                "component":
                    "source_runtime",

                "source_id":
                    source_id,
            },
        )


        safe_emit_event(
            "source.runtime_quarantined",
            entity="source",
            entity_id=source_id,
            severity="warning",
            actor="source_runtime",
            message="Corrupt Source runtime state moved to quarantine.",
            data={
                "reason":
                    reason,

                "quarantine_path":
                    (
                        str(target)
                        if target
                        else None
                    ),
            },
        )


    except Exception:

        # Runtime state itself remains recoverable.
        # Do not break Fetcher solely because evidence
        # collection failed.
        pass


    return {}

def _write_runtime_unlocked(
    path: Path,
    data: dict,
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
            encoding="utf-8",
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

        dir_fd = os.open(
            str(path.parent),
            os.O_DIRECTORY,
        )

        try:
            os.fsync(
                dir_fd
            )
        finally:
            os.close(
                dir_fd
            )

    finally:

        if os.path.exists(
            tmp
        ):
            os.unlink(
                tmp
            )


def read_runtime(
    source_id: str
):

    path = path_for(
        source_id
    )

    with lock_for(
        source_id
    ):
        return _read_runtime_unlocked(
            path
        )


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
        _write_runtime_unlocked(
            path,
            data,
        )


def update_runtime(
    source_id: str,
    **changes,
):

    path = path_for(
        source_id
    )

    with lock_for(
        source_id
    ):

        data = _read_runtime_unlocked(
            path
        )

        data.update(
            changes
        )

        _write_runtime_unlocked(
            path,
            data,
        )

        return data
