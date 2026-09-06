from __future__ import annotations

import hashlib
import json
import os
import tempfile
import time

from copy import deepcopy
from pathlib import Path
from typing import Any, Iterable


DEFAULT_VOLATILE_KEYS = frozenset({
    # Timestamps / write diagnostics
    "generated_at",
    "updated_at",
    "write_performed",
    "write_reason",

    # Per-run Tracker telemetry.
    # These describe the current invocation,
    # not the persisted lifecycle state.
    "processed_new_results",
    "unchanged_results",
})


def without_keys(
    value: dict[str, Any],
    ignored_keys: Iterable[str],
) -> dict[str, Any]:

    ignored = set(
        ignored_keys
    )

    return {
        key: deepcopy(item)
        for key, item
        in value.items()
        if key not in ignored
    }


def canonical_json_bytes(
    value: dict[str, Any],
) -> bytes:

    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            default=str,
        )
        + "\n"
    ).encode(
        "utf-8"
    )


def semantic_hash(
    value: dict[str, Any],
    *,
    ignored_keys: Iterable[str] = (),
) -> str:

    stable = without_keys(
        value,
        ignored_keys,
    )

    return hashlib.sha256(
        canonical_json_bytes(
            stable
        )
    ).hexdigest()


def existing_json(
    path: Path,
) -> dict[str, Any] | None:

    try:

        obj = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

    except Exception:
        return None


    if not isinstance(
        obj,
        dict,
    ):
        return None


    return obj


def json_semantically_equal(
    path: Path,
    value: dict[str, Any],
    *,
    ignored_keys: Iterable[str] = DEFAULT_VOLATILE_KEYS,
) -> bool:

    old = existing_json(
        path
    )

    if old is None:
        return False


    return (
        semantic_hash(
            old,
            ignored_keys=ignored_keys,
        )
        ==
        semantic_hash(
            value,
            ignored_keys=ignored_keys,
        )
    )


def atomic_json_write(
    path: Path,
    value: dict[str, Any],
    *,
    mode: int = 0o640,
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )


    fd, tmp = tempfile.mkstemp(
        dir=str(
            path.parent
        ),
        prefix="."
        + path.name
        + ".",
        suffix=".tmp",
    )


    try:

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as f:

            json.dump(
                value,
                f,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
                default=str,
            )

            f.write("\n")

            f.flush()

            os.fsync(
                f.fileno()
            )


        parent_gid = (
            path.parent.stat().st_gid
        )


        os.chown(
            tmp,
            -1,
            parent_gid,
        )


        os.chmod(
            tmp,
            mode,
        )


        os.replace(
            tmp,
            path,
        )


    finally:

        if os.path.exists(
            tmp
        ):
            os.unlink(
                tmp
            )


def atomic_json_if_changed(
    path: Path,
    value: dict[str, Any],
    *,
    mode: int = 0o640,
    ignored_keys: Iterable[str] = DEFAULT_VOLATILE_KEYS,
) -> bool:

    if json_semantically_equal(
        path,
        value,
        ignored_keys=ignored_keys,
    ):
        return False


    atomic_json_write(
        path,
        value,
        mode=mode,
    )

    return True


class HeartbeatGate:

    def __init__(
        self,
        *,
        heartbeat_seconds: float,
    ) -> None:

        self.heartbeat_seconds = float(
            heartbeat_seconds
        )

        self._last_write_monotonic: float | None = None
        self._last_semantic_hash: str | None = None


    def should_write(
        self,
        semantic_payload: dict[str, Any],
    ) -> tuple[bool, str]:

        now = time.monotonic()

        current_hash = semantic_hash(
            semantic_payload
        )


        if (
            self._last_semantic_hash
            != current_hash
        ):

            self._last_semantic_hash = (
                current_hash
            )

            self._last_write_monotonic = (
                now
            )

            return True, "state_changed"


        if (
            self._last_write_monotonic
            is None
        ):

            self._last_write_monotonic = (
                now
            )

            return True, "initial"


        if (
            now
            - self._last_write_monotonic
            >= self.heartbeat_seconds
        ):

            self._last_write_monotonic = (
                now
            )

            return True, "heartbeat"


        return False, "suppressed"
