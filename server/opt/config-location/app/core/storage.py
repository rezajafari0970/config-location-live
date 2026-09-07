from __future__ import annotations

import os
import json
import time
import tempfile
from pathlib import Path
from typing import Any

from filelock import FileLock


DATA_DIR = Path("/var/lib/config-location")
LOCK_DIR = DATA_DIR / "locks"

LOCK_DIR.mkdir(parents=True, exist_ok=True)


class JsonReadError(RuntimeError):
    pass


class JsonCorruptError(JsonReadError):
    pass


def fsync_directory(
    path: Path,
) -> None:
    path = Path(path)

    fd = os.open(
        str(path),
        os.O_DIRECTORY,
    )

    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _lock_for(path: Path) -> FileLock:
    safe = str(path).replace("/", "_")
    return FileLock(str(LOCK_DIR / f"{safe}.lock"), timeout=10)


def read_json(path: Path, default: Any):
    path = Path(path)

    with _lock_for(path):
        if not path.exists():
            return default

        try:
            with path.open("r", encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            return default


def read_json_strict(
    path: Path,
    default: Any,
):
    """
    Read JSON without silently converting corruption or
    filesystem errors into a default value.

    Missing file is the only condition that returns default.
    """

    path = Path(path)

    with _lock_for(path):

        if not path.exists():
            return default

        try:

            with path.open(
                "r",
                encoding="utf-8"
            ) as f:

                return json.load(f)

        except json.JSONDecodeError as exc:

            raise JsonCorruptError(
                f"json_corrupt:{path}"
            ) from exc

        except OSError as exc:

            raise JsonReadError(
                f"json_read_failed:{path}:"
                f"{type(exc).__name__}"
            ) from exc


def quarantine_file(
    path: Path,
    quarantine_dir: Path,
    *,
    reason: str,
    metadata: dict | None = None,
):
    """
    Atomically preserve an existing file in quarantine.

    The original bytes are moved, not rewritten.
    """

    path = Path(path)

    quarantine_dir = Path(
        quarantine_dir
    )

    quarantine_dir.mkdir(
        parents=True,
        exist_ok=True
    )

    with _lock_for(path):

        if not path.exists():
            return None

        stamp = (
            f"{time.time_ns()}."
            f"{os.getpid()}"
        )

        target = (
            quarantine_dir
            / (
                f"{path.name}."
                f"{stamp}."
                "quarantine"
            )
        )

        os.replace(
            path,
            target
        )

        fsync_directory(
            path.parent
        )

        if (
            target.parent
            != path.parent
        ):
            fsync_directory(
                target.parent
            )


    meta = {
        "reason": str(reason),
        "original_path": str(path),
        "quarantine_path": str(target),
        "quarantined_epoch_ns":
            time.time_ns(),
    }

    if isinstance(
        metadata,
        dict
    ):
        meta.update(
            metadata
        )


    atomic_write_json(
        target.with_name(
            target.name
            + ".meta.json"
        ),
        meta,
    )


    return target


def atomic_write_json(path: Path, data: Any):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    lock = _lock_for(path)

    with lock:
        fd, tmp_name = tempfile.mkstemp(
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=str(path.parent),
        )

        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(
                    data,
                    f,
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
                f.flush()
                os.fsync(f.fileno())

            os.replace(tmp_name, path)

            fsync_directory(
                path.parent
            )

        finally:
            if os.path.exists(tmp_name):
                os.unlink(tmp_name)
