from __future__ import annotations

import os
import json
import tempfile
from pathlib import Path
from typing import Any

from filelock import FileLock


DATA_DIR = Path("/var/lib/config-location")
LOCK_DIR = DATA_DIR / "locks"

LOCK_DIR.mkdir(parents=True, exist_ok=True)


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

            dir_fd = os.open(str(path.parent), os.O_DIRECTORY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)

        finally:
            if os.path.exists(tmp_name):
                os.unlink(tmp_name)
