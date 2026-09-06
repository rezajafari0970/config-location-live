from __future__ import annotations

import hashlib
import json
import os
import tempfile
import fcntl

from contextlib import contextmanager

from datetime import (
    datetime,
    timezone,
)

from pathlib import Path
from typing import Any


CACHE_ROOT=Path(
    "/var/lib/config-location/"
    "country/geo-cache"
)

DEFAULT_TTL_SECONDS=(
    7 * 24 * 60 * 60
)


def utc_now() -> datetime:
    return datetime.now(
        timezone.utc
    )


def _key(
    ip: str,
) -> str:

    return hashlib.sha256(
        ip.encode("utf-8")
    ).hexdigest()


def cache_path(
    ip: str,
) -> Path:

    return (
        CACHE_ROOT
        / f"{_key(ip)}.json"
    )


def lock_path(
    ip: str,
) -> Path:

    return (
        CACHE_ROOT
        / "locks"
        / f"{_key(ip)}.lock"
    )


@contextmanager
def geo_singleflight_lock(
    *,
    ip: str,
):

    """
    K4 per-IP cross-process single-flight.

    Different IPs never block each other.
    Same IP has exactly one lookup owner.
    """

    p=lock_path(ip)

    p.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd=os.open(
        p,
        os.O_RDWR
        | os.O_CREAT,
        0o600,
    )

    try:

        fcntl.flock(
            fd,
            fcntl.LOCK_EX,
        )

        yield

    finally:

        try:
            fcntl.flock(
                fd,
                fcntl.LOCK_UN,
            )
        finally:
            os.close(fd)


def _atomic_json(
    path: Path,
    value: dict[str, Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd,tmp=tempfile.mkstemp(
        dir=str(path.parent),
        prefix="."+path.name+".",
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
            )

            f.write("\n")
            f.flush()
            os.fsync(
                f.fileno()
            )

        os.replace(
            tmp,
            path,
        )

    except Exception:

        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass

        raise


def save_geo_cache(
    *,
    ip: str,
    value: dict[str, Any],
) -> Path:

    now=utc_now()

    o={
        "schema_version":1,
        "ip":ip,
        "cached_at":
            now.isoformat(),
        "cached_at_epoch":
            int(now.timestamp()),
        "value":value,
    }

    p=cache_path(ip)

    _atomic_json(
        p,
        o,
    )

    return p


def load_geo_cache(
    *,
    ip: str,
    ttl_seconds: int = DEFAULT_TTL_SECONDS,
) -> dict[str, Any] | None:

    p=cache_path(ip)

    if not p.exists():
        return None

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        return None

    if o.get("ip") != ip:
        return None

    epoch=o.get(
        "cached_at_epoch"
    )

    if not isinstance(
        epoch,
        int,
    ):
        return None

    age=(
        int(
            utc_now().timestamp()
        )
        - epoch
    )

    if age < 0:
        return None

    if age > ttl_seconds:
        return None

    value=o.get("value")

    if not isinstance(
        value,
        dict,
    ):
        return None

    return value
