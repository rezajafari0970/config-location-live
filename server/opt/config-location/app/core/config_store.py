from __future__ import annotations

import json
import os
import tempfile

from datetime import datetime, timezone
from pathlib import Path

from filelock import FileLock

from app.integrity.referential_guard import (
    archive_latest_before_config_delete,
)


DATA = Path(
    "/var/lib/config-location"
)

CONFIG_DIR = (
    DATA / "configs"
)

LOCK_DIR = (
    DATA / "locks"
)

SOURCE_SNAPSHOT_DIR = (
    DATA / "source-snapshots"
)

CORRUPT_CONFIG_DIR = (
    DATA
    / "quarantine"
    / "corrupt-configs"
)

SOURCE_TOMBSTONE_DIR = (
    DATA
    / "source-tombstones"
)

CONFIG_DIR.mkdir(
    parents=True,
    exist_ok=True
)

LOCK_DIR.mkdir(
    parents=True,
    exist_ok=True
)

SOURCE_SNAPSHOT_DIR.mkdir(
    parents=True,
    exist_ok=True
)

CORRUPT_CONFIG_DIR.mkdir(
    parents=True,
    exist_ok=True
)

SOURCE_TOMBSTONE_DIR.mkdir(
    parents=True,
    exist_ok=True
)


def _fsync_directory(
    path: Path
):
    fd = os.open(
        str(path),
        os.O_DIRECTORY,
    )

    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _quarantine_corrupt_config(
    path: Path,
    fingerprint: str,
    reason: str,
):
    """
    Preserve the exact broken record before creating
    a replacement record.
    """

    timestamp = datetime.now(
        timezone.utc
    ).strftime(
        "%Y%m%dT%H%M%S.%fZ"
    )

    target = (
        CORRUPT_CONFIG_DIR
        / (
            f"{fingerprint}."
            f"{timestamp}."
            f"{os.getpid()}."
            "corrupt.json"
        )
    )

    os.replace(
        path,
        target,
    )

    _fsync_directory(
        path.parent
    )

    _fsync_directory(
        target.parent
    )

    _atomic_write(
        target.with_suffix(
            target.suffix
            + ".meta.json"
        ),
        {
            "fingerprint": fingerprint,
            "reason": str(reason),
            "quarantined_at": now_iso(),
            "original_path": str(path),
            "quarantine_path": str(target),
        },
    )

    return target


def _config_record_is_valid(
    record,
    fingerprint: str,
):
    return (
        isinstance(record, dict)
        and bool(record)
        and str(
            record.get(
                "id",
                ""
            )
        ) == str(
            fingerprint
        )
        and isinstance(
            record.get(
                "source_ids"
            ),
            list
        )
        and isinstance(
            record.get(
                "raw"
            ),
            str
        )
        and isinstance(
            record.get(
                "type"
            ),
            str
        )
    )


def _source_tombstone_path(
    source_id: str
):
    return (
        SOURCE_TOMBSTONE_DIR
        / f"{source_id}.json"
    )


def mark_source_deleted(
    source_id: str,
    reason: str = "source_deleted",
):
    source_id = str(
        source_id or ""
    ).strip()

    if not source_id:
        return False

    _atomic_write(
        _source_tombstone_path(
            source_id
        ),
        {
            "source_id": source_id,
            "deleted_at": now_iso(),
            "reason": str(reason),
        },
    )

    return True


def clear_source_deleted(
    source_id: str
):
    path = _source_tombstone_path(
        str(
            source_id
        ).strip()
    )

    try:
        path.unlink()

        _fsync_directory(
            path.parent
        )

        return True

    except FileNotFoundError:
        return False


def is_source_deleted(
    source_id: str
):
    source_id = str(
        source_id or ""
    ).strip()

    return bool(
        source_id
        and _source_tombstone_path(
            source_id
        ).exists()
    )


def now_iso():
    return datetime.now(
        timezone.utc
    ).isoformat()


def _path(
    fingerprint: str
):
    return (
        CONFIG_DIR
        / f"{fingerprint}.json"
    )


def _lock(
    fingerprint: str
):
    return FileLock(
        str(
            LOCK_DIR
            / f"config-{fingerprint}.lock"
        ),
        timeout=15,
    )


def _atomic_write(
    path: Path,
    data: dict
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


def upsert_config(
    item: dict,
    source_id: str,
):
    fingerprint = item[
        "fingerprint"
    ]

    path = _path(
        fingerprint
    )

    # Prevent a fetch response that was already in-flight
    # from resurrecting ownership after Source deletion.
    if is_source_deleted(
        source_id
    ):
        return (
            {
                "id": fingerprint,
                "source_ids": [],
                "ignored_deleted_source": True,
            },
            False,
        )

    with _lock(
        fingerprint
    ):

        if path.exists():

            try:
                record = json.loads(
                    path.read_text(
                        encoding="utf-8"
                    )
                )

            except Exception as exc:

                _quarantine_corrupt_config(
                    path,
                    fingerprint,
                    "json_decode_error:"
                    + type(exc).__name__,
                )

                record = {}

            else:

                if not _config_record_is_valid(
                    record,
                    fingerprint,
                ):

                    _quarantine_corrupt_config(
                        path,
                        fingerprint,
                        "invalid_config_record_schema",
                    )

                    record = {}

        else:
            record = {}

        created = not bool(
            record
        )

        sources = set(
            record.get(
                "source_ids",
                []
            )
        )

        sources.add(
            source_id
        )

        now = now_iso()

        if created:
            record = {
                "id": fingerprint,
                "type": item["type"],
                "raw": item["raw"],
                "canonical": item.get(
                    "canonical",
                    item["raw"],
                ),
                "first_seen_at": now,
                "last_seen_at": now,
                "source_ids": sorted(
                    sources
                ),
            }
        else:
            record[
                "last_seen_at"
            ] = now

            record[
                "source_ids"
            ] = sorted(
                sources
            )

        _atomic_write(
            path,
            record
        )

        return (
            record,
            created
        )


def list_configs():
    result = []

    for path in CONFIG_DIR.glob(
        "*.json"
    ):
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
                result.append(
                    obj
                )
        except Exception:
            continue

    result.sort(
        key=lambda x:
            x.get(
                "last_seen_at",
                ""
            ),
        reverse=True
    )

    return result


def config_stats():
    total = 0
    types = {}

    for item in list_configs():
        total += 1

        kind = item.get(
            "type",
            "unknown"
        )

        types[kind] = (
            types.get(
                kind,
                0
            )
            + 1
        )

    return {
        "total": total,
        "types": types,
    }


def detach_source_from_configs(source_id: str):
    """
    Remove a source from Config ownership while holding
    the same per-config lock used by upsert/reconciliation.
    """

    source_id = str(
        source_id or ""
    ).strip()

    if not source_id:
        return {
            "scanned": 0,
            "detached": 0,
            "deleted": 0,
            "kept": 0,
        }

    scanned = 0
    detached = 0
    deleted = 0
    kept = 0

    for path in list(
        CONFIG_DIR.glob(
            "*.json"
        )
    ):

        scanned += 1

        with _lock(
            path.stem
        ):

            if not path.exists():
                continue

            try:
                record = json.loads(
                    path.read_text(
                        encoding="utf-8"
                    )
                )
            except Exception:
                continue

            if not isinstance(
                record,
                dict
            ):
                continue

            sources = record.get(
                "source_ids",
                []
            )

            if not isinstance(
                sources,
                list
            ):
                sources = []

            source_set = {
                str(x)
                for x in sources
                if x
            }

            if source_id not in source_set:
                continue

            detached += 1

            source_set.discard(
                source_id
            )

            if source_set:

                record[
                    "source_ids"
                ] = sorted(
                    source_set
                )

                _atomic_write(
                    path,
                    record
                )

                kept += 1

            else:

                archive_latest_before_config_delete(
                    path.stem,
                    reason="detach_source_last_owner",
                )

                try:
                    path.unlink()
                    deleted += 1

                except FileNotFoundError:
                    pass

    remove_source_snapshot(
        source_id
    )

    return {
        "scanned": scanned,
        "detached": detached,
        "deleted": deleted,
        "kept": kept,
    }

def detach_sources_from_configs(source_ids):
    """
    Bulk ownership detach under the per-config lock.
    """

    ids = {
        str(x).strip()
        for x in source_ids
        if str(x).strip()
    }

    if not ids:
        return {
            "scanned": 0,
            "detached": 0,
            "deleted": 0,
            "kept": 0,
        }

    scanned = 0
    detached = 0
    deleted = 0
    kept = 0

    for path in list(
        CONFIG_DIR.glob(
            "*.json"
        )
    ):

        scanned += 1

        with _lock(
            path.stem
        ):

            if not path.exists():
                continue

            try:
                record = json.loads(
                    path.read_text(
                        encoding="utf-8"
                    )
                )
            except Exception:
                continue

            if not isinstance(
                record,
                dict
            ):
                continue

            sources = record.get(
                "source_ids",
                []
            )

            if not isinstance(
                sources,
                list
            ):
                sources = []

            old_set = {
                str(x)
                for x in sources
                if x
            }

            if not (
                old_set
                & ids
            ):
                continue

            detached += 1

            new_set = (
                old_set
                - ids
            )

            if new_set:

                record[
                    "source_ids"
                ] = sorted(
                    new_set
                )

                _atomic_write(
                    path,
                    record
                )

                kept += 1

            else:

                archive_latest_before_config_delete(
                    path.stem,
                    reason="detach_sources_last_owner",
                )

                try:
                    path.unlink()
                    deleted += 1

                except FileNotFoundError:
                    pass

    remove_source_snapshots(
        ids
    )

    return {
        "scanned": scanned,
        "detached": detached,
        "deleted": deleted,
        "kept": kept,
    }

def _source_snapshot_path(
    source_id: str
):
    source_id = str(
        source_id
    ).strip()

    return (
        SOURCE_SNAPSHOT_DIR
        / f"{source_id}.json"
    )


def _source_snapshot_lock(
    source_id: str
):
    source_id = str(
        source_id
    ).strip()

    return FileLock(
        str(
            LOCK_DIR
            / f"source-snapshot-{source_id}.lock"
        ),
        timeout=30,
    )


def _read_source_snapshot_unlocked(
    source_id: str
):
    path = _source_snapshot_path(
        source_id
    )

    if not path.exists():
        return None

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
        dict
    ):
        return None

    values = obj.get(
        "fingerprints"
    )

    if not isinstance(
        values,
        list
    ):
        return None

    return {
        str(x).strip()
        for x in values
        if str(x).strip()
    }


def read_source_snapshot(
    source_id: str
):
    source_id = str(
        source_id or ""
    ).strip()

    if not source_id:
        return None

    with _source_snapshot_lock(
        source_id
    ):
        return _read_source_snapshot_unlocked(
            source_id
        )


def _write_source_snapshot_unlocked(
    source_id: str,
    fingerprints,
):
    values = sorted({
        str(x).strip()
        for x in fingerprints
        if str(x).strip()
    })

    data = {
        "source_id": source_id,
        "updated_at": now_iso(),
        "count": len(values),
        "fingerprints": values,
    }

    _atomic_write(
        _source_snapshot_path(
            source_id
        ),
        data
    )

    return data


def write_source_snapshot(
    source_id: str,
    fingerprints,
):
    source_id = str(
        source_id or ""
    ).strip()

    if not source_id:
        raise ValueError(
            "source_id is required"
        )

    with _source_snapshot_lock(
        source_id
    ):
        return _write_source_snapshot_unlocked(
            source_id,
            fingerprints,
        )


def _remove_source_snapshot_unlocked(
    source_id: str
):
    path = _source_snapshot_path(
        source_id
    )

    try:
        path.unlink()

        _fsync_directory(
            path.parent
        )

        return True

    except FileNotFoundError:
        return False


def remove_source_snapshot(
    source_id: str
):
    source_id = str(
        source_id or ""
    ).strip()

    if not source_id:
        return False

    with _source_snapshot_lock(
        source_id
    ):
        return _remove_source_snapshot_unlocked(
            source_id
        )


def remove_source_snapshots(
    source_ids
):
    removed = 0

    for source_id in sorted({
        str(x).strip()
        for x in source_ids
        if str(x).strip()
    }):

        with _source_snapshot_lock(
            source_id
        ):

            if _remove_source_snapshot_unlocked(
                source_id
            ):
                removed += 1

    return removed


def delete_all_source_snapshots():
    removed = 0

    for path in sorted(
        SOURCE_SNAPSHOT_DIR.glob(
            "*.json"
        ),
        key=lambda p: p.name,
    ):

        source_id = path.stem

        with _source_snapshot_lock(
            source_id
        ):

            if _remove_source_snapshot_unlocked(
                source_id
            ):
                removed += 1

    return removed

def sync_source_snapshot(
    source_id: str,
    current_fingerprints,
    authoritative: bool = True,
):
    """
    Synchronize ownership for exactly ONE source.

    IMPORTANT:

    Only an authoritative/complete source cycle is allowed
    to remove old ownership.

    New configs are already attached by upsert_config().

    For fingerprints that existed in the previous
    authoritative source snapshot but are absent now:

        - remove this source_id from source_ids
        - keep config if another source owns it
        - delete config if no source remains

    The first successful authoritative cycle only creates
    a baseline and does not delete anything.
    """

    source_id = str(
        source_id or ""
    ).strip()

    current = {
        str(x).strip()
        for x in current_fingerprints
        if str(x).strip()
    }

    result = {
        "source_id": source_id,

        "authoritative":
            bool(authoritative),

        "current":
            len(current),

        "previous":
            0,

        "missing":
            0,

        "detached":
            0,

        "deleted":
            0,

        "kept_shared":
            0,

        "baseline_created":
            False,

        "snapshot_updated":
            False,
    }

    if not source_id:
        return result

    if is_source_deleted(
        source_id
    ):
        result[
            "source_deleted"
        ] = True

        return result

    if not authoritative:
        return result

    with _source_snapshot_lock(
        source_id
    ):

        previous = _read_source_snapshot_unlocked(
            source_id
        )

        # First authoritative cycle:
        # establish baseline only.
        if previous is None:

            _write_source_snapshot_unlocked(
                source_id,
                current
            )

            result[
                "baseline_created"
            ] = True

            result[
                "snapshot_updated"
            ] = True

            return result

        result[
            "previous"
        ] = len(
            previous
        )

        missing = (
            previous
            - current
        )

        result[
            "missing"
        ] = len(
            missing
        )

        for fingerprint in missing:

            path = _path(
                fingerprint
            )

            if not path.exists():
                continue

            with _lock(
                fingerprint
            ):

                if not path.exists():
                    continue

                try:
                    record = json.loads(
                        path.read_text(
                            encoding="utf-8"
                        )
                    )
                except Exception:
                    continue

                if not isinstance(
                    record,
                    dict
                ):
                    continue

                sources = record.get(
                    "source_ids",
                    []
                )

                if not isinstance(
                    sources,
                    list
                ):
                    sources = []

                source_set = {
                    str(x)
                    for x in sources
                    if x
                }

                if source_id not in source_set:
                    continue

                source_set.discard(
                    source_id
                )

                result[
                    "detached"
                ] += 1

                if source_set:

                    record[
                        "source_ids"
                    ] = sorted(
                        source_set
                    )

                    _atomic_write(
                        path,
                        record
                    )

                    result[
                        "kept_shared"
                    ] += 1

                else:

                    try:
                        archive_latest_before_config_delete(
                            path.stem,
                            reason="source_snapshot_last_owner",
                        )

                        path.unlink()

                        result[
                            "deleted"
                        ] += 1

                    except FileNotFoundError:
                        pass

        _write_source_snapshot_unlocked(
            source_id,
            current
        )

        result[
            "snapshot_updated"
        ] = True

    return result

def delete_all_configs():
    """
    Delete every Config under the same per-config lock
    domain used by upsert and ownership reconciliation.
    """

    delete_all_source_snapshots()

    deleted = 0

    for path in list(
        CONFIG_DIR.glob(
            "*.json"
        )
    ):

        fingerprint = path.stem

        with _lock(
            fingerprint
        ):

            if not path.exists():
                continue

            archive_latest_before_config_delete(
                fingerprint,
                reason="delete_all_configs",
            )

            try:
                path.unlink()

                _fsync_directory(
                    path.parent
                )

                deleted += 1

            except FileNotFoundError:
                pass

    return deleted

