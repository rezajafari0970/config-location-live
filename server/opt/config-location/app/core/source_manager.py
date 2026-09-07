from __future__ import annotations

import os
import uuid
from functools import wraps
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from filelock import FileLock

from .storage import (
    read_json,
    read_json_strict,
    atomic_write_json,
    quarantine_file,
    fsync_directory,
    JsonCorruptError,
    JsonReadError,
)


from .events import (
    safe_emit_event,
)

from .mutation import (
    mutation_result,
    mutation_error,
)


from app.core.config_store import (
    detach_source_from_configs,
    detach_sources_from_configs,
    delete_all_configs,
    mark_source_deleted,
    clear_source_deleted,
)



SOURCE_FILE = Path("/var/lib/config-location/sources/sources.json")

SOURCE_TRANSACTION_LOCK = Path(
    "/var/lib/config-location/locks/"
    "source-manager-transaction.lock"
)

SOURCE_DELETE_JOURNAL = Path(
    "/var/lib/config-location/state/"
    "pending-source-deletion.json"
)

SOURCE_DELETE_JOURNAL_QUARANTINE_DIR = Path(
    "/var/lib/config-location/quarantine/"
    "source-deletion-journal"
)

SOURCE_DELETE_JOURNAL_BLOCK_MARKER = Path(
    "/var/lib/config-location/state/"
    "source-deletion-journal-blocked.json"
)


class SourceDeletionJournalCorruptError(
    RuntimeError
):
    pass


SOURCE_REGISTRY_QUARANTINE_DIR = Path(
    "/var/lib/config-location/quarantine/"
    "source-registry"
)

SOURCE_REGISTRY_BLOCK_MARKER = Path(
    "/var/lib/config-location/state/"
    "source-registry-blocked.json"
)


class SourceRegistryCorruptError(
    RuntimeError
):
    pass


def _validate_source_registry(
    data,
):
    if not isinstance(
        data,
        dict
    ):
        return False

    sources = data.get(
        "sources"
    )

    if not isinstance(
        sources,
        list
    ):
        return False

    for source in sources:

        if not isinstance(
            source,
            dict
        ):
            return False

        if not str(
            source.get(
                "id",
                ""
            )
        ).strip():
            return False

    return True


def _quarantine_source_registry(
    reason: str,
):
    target = quarantine_file(
        SOURCE_FILE,
        SOURCE_REGISTRY_QUARANTINE_DIR,
        reason=reason,
        metadata={
            "component":
                "source-registry",
        },
    )

    atomic_write_json(
        SOURCE_REGISTRY_BLOCK_MARKER,
        {
            "blocked": True,
            "reason": str(reason),
            "quarantine_path":
                str(target)
                if target
                else None,
            "blocked_at": now_iso(),
        },
    )

    safe_emit_event(
        "source.registry_quarantined",
        entity="source_registry",
        severity="critical",
        actor="source_manager",
        message="Source Registry was quarantined and blocked.",
        data={
            "reason":
                str(reason),

            "quarantine_path":
                (
                    str(target)
                    if target
                    else None
                ),
        },
    )

    return target


def _write_delete_journal(
    operation: str,
    source_ids,
):
    atomic_write_json(
        SOURCE_DELETE_JOURNAL,
        {
            "operation": str(operation),
            "source_ids": sorted({
                str(x).strip()
                for x in source_ids
                if str(x).strip()
            }),
            "created_at": now_iso(),
        },
    )


def _quarantine_delete_journal(
    reason: str,
):
    target = quarantine_file(
        SOURCE_DELETE_JOURNAL,
        SOURCE_DELETE_JOURNAL_QUARANTINE_DIR,
        reason=reason,
        metadata={
            "component":
                "source-deletion-journal",
        },
    )

    atomic_write_json(
        SOURCE_DELETE_JOURNAL_BLOCK_MARKER,
        {
            "blocked": True,
            "reason": str(reason),
            "quarantine_path":
                str(target)
                if target
                else None,
            "blocked_at": now_iso(),
        },
    )

    safe_emit_event(
        "source.deletion_journal_quarantined",
        entity="source_deletion_journal",
        severity="critical",
        actor="source_manager",
        message="Source deletion journal was quarantined and blocked.",
        data={
            "reason":
                str(reason),

            "quarantine_path":
                (
                    str(target)
                    if target
                    else None
                ),
        },
    )

    return target


def _prepare_source_deletion(
    operation: str,
    source_ids,
):
    values = sorted({
        str(x).strip()
        for x in source_ids
        if str(x).strip()
    })


    if not values:
        return []


    # Journal FIRST.
    _write_delete_journal(
        operation,
        values,
    )


    marked = []


    try:

        for source_id in values:

            mark_source_deleted(
                source_id,
                reason=operation,
            )

            marked.append(
                source_id
            )


    except Exception:

        for source_id in marked:

            try:
                clear_source_deleted(
                    source_id
                )
            except Exception:
                pass


        _clear_delete_journal()

        raise


    return values


def _read_delete_journal():

    if SOURCE_DELETE_JOURNAL_BLOCK_MARKER.exists():

        raise SourceDeletionJournalCorruptError(
            "source_deletion_journal_blocked"
        )


    if not SOURCE_DELETE_JOURNAL.exists():
        return None


    try:

        data = read_json_strict(
            SOURCE_DELETE_JOURNAL,
            None,
        )

    except JsonCorruptError as exc:

        target = _quarantine_delete_journal(
            "json_decode_error"
        )

        raise SourceDeletionJournalCorruptError(
            "source_deletion_journal_corrupt:"
            + str(target)
        ) from exc


    except JsonReadError as exc:

        raise SourceDeletionJournalCorruptError(
            "source_deletion_journal_read_failed"
        ) from exc


    if not isinstance(
        data,
        dict
    ):

        target = _quarantine_delete_journal(
            "invalid_journal_schema"
        )

        raise SourceDeletionJournalCorruptError(
            "source_deletion_journal_invalid_schema:"
            + str(target)
        )


    operation = str(
        data.get(
            "operation",
            ""
        )
    )


    if operation not in {
        "delete_source",
        "delete_sources",
        "delete_all",
    }:

        target = _quarantine_delete_journal(
            "invalid_journal_operation"
        )

        raise SourceDeletionJournalCorruptError(
            "source_deletion_journal_invalid_operation:"
            + str(target)
        )


    ids = data.get(
        "source_ids"
    )


    if not isinstance(
        ids,
        list
    ):

        target = _quarantine_delete_journal(
            "invalid_source_ids_schema"
        )

        raise SourceDeletionJournalCorruptError(
            "source_deletion_journal_invalid_ids:"
            + str(target)
        )


    return data

def _clear_delete_journal():

    try:

        SOURCE_DELETE_JOURNAL.unlink()

        fsync_directory(
            SOURCE_DELETE_JOURNAL.parent
        )

        return True

    except FileNotFoundError:

        return False

def _recover_pending_source_deletion_unlocked():

    journal = _read_delete_journal()

    if not journal:
        return False

    values = {
        str(x).strip()
        for x in journal.get(
            "source_ids",
            []
        )
        if str(x).strip()
    }

    operation = str(
        journal.get(
            "operation",
            ""
        )
    )

    data = _load()

    live_ids = {
        str(
            source.get(
                "id"
            )
        )
        for source in data[
            "sources"
        ]
    }

    absent = (
        values
        - live_ids
    )

    for source_id in absent:

        mark_source_deleted(
            source_id,
            reason="deletion_recovery",
        )

    if (
        operation == "delete_all"
        and not live_ids
    ):

        delete_all_configs()

    elif absent:

        detach_sources_from_configs(
            absent
        )

    for source_id in (
        values
        & live_ids
    ):

        clear_source_deleted(
            source_id
        )

    _clear_delete_journal()

    safe_emit_event(
        "source.deletion_recovered",
        entity="source",
        severity="warning",
        actor="source_manager",
        message="Interrupted Source deletion transaction was recovered.",
        data={
            "operation":
                operation,

            "source_ids":
                sorted(values),

            "absent_source_ids":
                sorted(absent),
        },
    )

    return True


def recover_pending_source_deletions():

    if SOURCE_DELETE_JOURNAL_BLOCK_MARKER.exists():

        raise SourceDeletionJournalCorruptError(
            "source_deletion_journal_blocked"
        )

    if not SOURCE_DELETE_JOURNAL.exists():
        return False

    SOURCE_TRANSACTION_LOCK.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    with FileLock(
        str(SOURCE_TRANSACTION_LOCK),
        timeout=60,
    ):

        return _recover_pending_source_deletion_unlocked()


def _source_transaction(func):

    @wraps(func)
    def wrapped(*args, **kwargs):

        SOURCE_TRANSACTION_LOCK.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        with FileLock(
            str(SOURCE_TRANSACTION_LOCK),
            timeout=60,
        ):

            _recover_pending_source_deletion_unlocked()

            return func(
                *args,
                **kwargs,
            )

    return wrapped


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def normalize_url(url: str) -> str:
    url = (url or "").strip()

    parsed = urlsplit(url)

    if parsed.scheme.lower() not in ("http", "https"):
        raise ValueError("Only http:// and https:// source URLs are allowed.")

    if not parsed.hostname:
        raise ValueError("URL hostname is missing.")

    scheme = parsed.scheme.lower()
    hostname = parsed.hostname.lower()

    # urlsplit().hostname strips brackets around IPv6
    # literals.  Restore them before rebuilding netloc.
    host_for_netloc = (
        f"[{hostname}]"
        if ":" in hostname
        else hostname
    )

    port = parsed.port

    if port:
        default = (
            scheme == "http" and port == 80
        ) or (
            scheme == "https" and port == 443
        )

        netloc = (
            host_for_netloc
            if default
            else f"{host_for_netloc}:{port}"
        )
    else:
        netloc = host_for_netloc

    if parsed.username or parsed.password:
        raise ValueError("Credentials inside source URLs are not allowed.")

    path = parsed.path or "/"

    # Fragment is not sent to HTTP server.
    normalized = urlunsplit(
        (
            scheme,
            netloc,
            path,
            parsed.query,
            "",
        )
    )

    return normalized


def _load():

    if SOURCE_REGISTRY_BLOCK_MARKER.exists():

        raise SourceRegistryCorruptError(
            "source_registry_blocked"
        )


    default = {
        "version": 1,
        "sources": [],
    }


    try:

        data = read_json_strict(
            SOURCE_FILE,
            default,
        )


    except JsonCorruptError as exc:

        target = _quarantine_source_registry(
            "json_decode_error"
        )

        raise SourceRegistryCorruptError(
            "source_registry_corrupt:"
            + str(target)
        ) from exc


    except JsonReadError as exc:

        # Filesystem failures are not treated as an
        # empty registry and are not overwritten.
        raise SourceRegistryCorruptError(
            "source_registry_read_failed"
        ) from exc


    if not _validate_source_registry(
        data
    ):

        target = _quarantine_source_registry(
            "invalid_registry_schema"
        )

        raise SourceRegistryCorruptError(
            "source_registry_invalid_schema:"
            + str(target)
        )


    return data


def _save(data):
    atomic_write_json(SOURCE_FILE, data)


def list_sources():

    if SOURCE_DELETE_JOURNAL.exists():
        recover_pending_source_deletions()

    data = _load()

    return sorted(
        data["sources"],
        key=lambda s: s.get("created_at", ""),
        reverse=True,
    )


def get_source(source_id: str):
    for source in list_sources():
        if source.get("id") == source_id:
            return source

    return None


@_source_transaction
def add_source(
    url: str,
    name: str = "",
    interval: int = 60,
):
    normalized = normalize_url(url)

    interval = int(interval)

    if interval < 10:
        interval = 10

    if interval > 86400:
        interval = 86400

    data = _load()

    for source in data["sources"]:
        if source.get("normalized_url") == normalized:

            source["enabled"] = True

            if name.strip():
                source["name"] = name.strip()

            source["fetch_interval_seconds"] = interval
            source["updated_at"] = now_iso()
            source["duplicate_add_count"] = int(
                source.get("duplicate_add_count", 0)
            ) + 1

            _save(data)

            return source, True

    timestamp = now_iso()

    source = {
        "id": str(uuid.uuid4()),
        "name": name.strip(),
        "url": url.strip(),
        "normalized_url": normalized,

        "enabled": True,

        "fetch_interval_seconds": interval,

        "fetch_mode": "auto",

        "created_at": timestamp,
        "updated_at": timestamp,

        "last_fetch_at": None,
        "last_success_at": None,
        "last_error": None,

        "total_fetches": 0,
        "total_success": 0,
        "total_errors": 0,

        "duplicate_add_count": 0,

        "stats": {
            "raw_responses": 0,
            "configs_seen": 0,
            "unique_configs": 0
        }
    }

    data["sources"].append(source)

    _save(data)

    return source, False


@_source_transaction
def edit_source(
    source_id: str,
    url: str,
    name: str,
    interval: int,
):
    normalized = normalize_url(url)

    interval = max(10, min(int(interval), 86400))

    data = _load()

    target = None

    for source in data["sources"]:
        if source.get("id") == source_id:
            target = source
            break

    if not target:
        raise KeyError("Source not found.")

    for source in data["sources"]:
        if (
            source.get("id") != source_id
            and source.get("normalized_url") == normalized
        ):
            raise ValueError(
                "This URL already belongs to another source."
            )

    old_url = target.get("normalized_url")

    target["name"] = name.strip()
    target["url"] = url.strip()
    target["normalized_url"] = normalized
    target["fetch_interval_seconds"] = interval
    target["updated_at"] = now_iso()

    if old_url != normalized:
        target["url_generation"] = (
            int(target.get("url_generation", 0)) + 1
        )

        target["last_fetch_at"] = None
        target["last_success_at"] = None
        target["last_error"] = None

    _save(data)

    return target


@_source_transaction
def delete_source(source_id: str):

    source_id = str(
        source_id
    )

    data = _load()

    new_sources = [
        source
        for source in data[
            "sources"
        ]
        if str(
            source.get(
                "id"
            )
        ) != source_id
    ]


    if len(
        new_sources
    ) == len(
        data[
            "sources"
        ]
    ):
        return False


    _prepare_source_deletion(
        "delete_source",
        [source_id],
    )


    registry_saved = False


    try:

        data[
            "sources"
        ] = new_sources

        _save(
            data
        )

        registry_saved = True


        detach_source_from_configs(
            source_id
        )


        _clear_delete_journal()


        safe_emit_event(
            "source.deleted",
            entity="source",
            entity_id=source_id,
            severity="info",
            actor="source_manager",
            message="Source deleted successfully.",
            data={
                "operation":
                    "delete_source",
            },
        )


        return True


    except Exception:

        if not registry_saved:

            try:

                clear_source_deleted(
                    source_id
                )

            finally:

                _clear_delete_journal()


        raise


@_source_transaction
def set_enabled(source_id: str, enabled: bool):
    data = _load()

    for source in data["sources"]:
        if source.get("id") == source_id:

            source["enabled"] = bool(enabled)
            source["updated_at"] = now_iso()

            _save(data)

            return source

    raise KeyError("Source not found.")


def stats():
    sources = list_sources()

    return {
        "total": len(sources),
        "enabled": sum(
            1 for s in sources
            if s.get("enabled")
        ),
        "disabled": sum(
            1 for s in sources
            if not s.get("enabled")
        ),
    }


@_source_transaction
def add_sources_bulk(
    urls,
    interval=60,
    fetch_mode="auto",
    enabled=True,
    fetch_immediately=False,
):
    """
    Bulk source import.

    urls:
        iterable of URLs

    returns:
        {
            received,
            valid_lines,
            added,
            merged,
            invalid,
            invalid_items,
            sources
        }
    """

    interval = max(
        10,
        min(
            int(interval),
            86400
        )
    )

    allowed_modes = {
        "auto",
        "bulk",
        "rotating",
    }

    if fetch_mode not in allowed_modes:
        fetch_mode = "auto"

    received = 0
    normalized_seen = set()

    cleaned = []
    invalid_items = []

    for raw in urls:

        received += 1

        raw = str(raw or "").strip()

        if not raw:
            continue

        try:
            normalized = normalize_url(raw)

        except Exception as e:
            invalid_items.append({
                "url": raw,
                "error": str(e),
            })
            continue

        if normalized in normalized_seen:
            continue

        normalized_seen.add(
            normalized
        )

        cleaned.append(
            (
                raw,
                normalized
            )
        )

    data = _load()

    existing_by_url = {
        source.get("normalized_url"):
            source

        for source in data["sources"]

        if source.get("normalized_url")
    }

    added = 0
    merged = 0

    output_sources = []

    timestamp = now_iso()

    for raw, normalized in cleaned:

        existing = existing_by_url.get(
            normalized
        )

        if existing:

            merged += 1

            existing["enabled"] = bool(
                enabled
            )

            existing[
                "fetch_interval_seconds"
            ] = interval

            existing[
                "fetch_mode"
            ] = fetch_mode

            existing[
                "fetch_immediately"
            ] = bool(
                fetch_immediately
            )

            existing[
                "duplicate_add_count"
            ] = int(
                existing.get(
                    "duplicate_add_count",
                    0
                )
            ) + 1

            existing[
                "updated_at"
            ] = timestamp

            output_sources.append(
                existing
            )

            continue

        source = {
            "id": str(
                uuid.uuid4()
            ),

            "name": "",

            "url": raw,

            "normalized_url":
                normalized,

            "enabled":
                bool(enabled),

            "fetch_interval_seconds":
                interval,

            "fetch_mode":
                fetch_mode,

            "fetch_immediately":
                bool(fetch_immediately),

            "created_at":
                timestamp,

            "updated_at":
                timestamp,

            "last_fetch_at":
                None,

            "last_success_at":
                None,

            "last_error":
                None,

            "total_fetches":
                0,

            "total_success":
                0,

            "total_errors":
                0,

            "duplicate_add_count":
                0,

            "stats": {
                "raw_responses": 0,
                "configs_seen": 0,
                "unique_configs": 0
            }
        }

        data["sources"].append(
            source
        )

        existing_by_url[
            normalized
        ] = source

        output_sources.append(
            source
        )

        added += 1

    _save(
        data
    )

    return {
        "received":
            received,

        "valid_lines":
            len(cleaned),

        "added":
            added,

        "merged":
            merged,

        "invalid":
            len(
                invalid_items
            ),

        "invalid_items":
            invalid_items,

        "sources":
            output_sources,
    }


@_source_transaction
def delete_sources(source_ids):

    ids = {
        str(source_id)
        for source_id in source_ids
        if source_id
    }


    if not ids:
        return 0


    data = _load()


    existing_ids = {
        str(
            source.get(
                "id"
            )
        )
        for source in data[
            "sources"
        ]
    }


    actual_ids = (
        ids
        & existing_ids
    )


    if not actual_ids:
        return 0


    prepared = set(
        _prepare_source_deletion(
            "delete_sources",
            actual_ids,
        )
    )


    registry_saved = False


    try:

        data[
            "sources"
        ] = [
            source
            for source in data[
                "sources"
            ]
            if str(
                source.get(
                    "id"
                )
            ) not in prepared
        ]


        _save(
            data
        )

        registry_saved = True


        detach_sources_from_configs(
            prepared
        )


        _clear_delete_journal()


        return len(
            prepared
        )


    except Exception:

        if not registry_saved:

            try:

                for source_id in prepared:

                    clear_source_deleted(
                        source_id
                    )

            finally:

                _clear_delete_journal()


        raise


@_source_transaction
def delete_all_sources():

    data = _load()


    ids = {
        str(
            source.get(
                "id"
            )
        )
        for source in data[
            "sources"
        ]
        if source.get(
            "id"
        )
    }


    if not ids:
        return 0


    prepared = set(
        _prepare_source_deletion(
            "delete_all",
            ids,
        )
    )


    registry_saved = False


    try:

        data[
            "sources"
        ] = []

        _save(
            data
        )

        registry_saved = True


        delete_all_configs()


        _clear_delete_journal()


        return len(
            prepared
        )


    except Exception:

        if not registry_saved:

            try:

                for source_id in prepared:

                    clear_source_deleted(
                        source_id
                    )

            finally:

                _clear_delete_journal()


        raise



# ============================================================
# PANEL / CONTROL-PLANE STRUCTURED MUTATION CONTRACT
# ============================================================

def delete_source_result(
    source_id: str,
    *,
    actor: str = "panel",
    reason: str = "source_delete_requested",
):
    """
    Structured control-plane wrapper.

    Existing delete_source() remains bool-compatible.
    """

    try:

        changed = bool(
            delete_source(
                source_id
            )
        )


        result = mutation_result(
            "delete_source",
            entity="source",
            entity_id=source_id,
            status=(
                "deleted"
                if changed
                else "not_found"
            ),
            changed=changed,
            actor=actor,
            reason=reason,
        )


        safe_emit_event(
            "source.delete_result",
            entity="source",
            entity_id=source_id,
            severity=(
                "info"
                if changed
                else "warning"
            ),
            actor=actor,
            message="Structured Source deletion result.",
            data=result,
        )


        return result


    except Exception as exc:

        result = mutation_error(
            "delete_source",
            entity="source",
            entity_id=source_id,
            actor=actor,
            reason=reason,
            error=(
                type(exc).__name__
                + ":"
                + str(exc)
            ),
        )


        safe_emit_event(
            "source.delete_failed",
            entity="source",
            entity_id=source_id,
            severity="error",
            actor=actor,
            message="Structured Source deletion failed.",
            data=result,
        )


        return result


def delete_sources_result(
    source_ids,
    *,
    actor: str = "panel",
    reason: str = "bulk_source_delete_requested",
):
    values = sorted({
        str(x)
        for x in source_ids
        if x
    })


    try:

        deleted = int(
            delete_sources(
                values
            )
        )


        return mutation_result(
            "delete_sources",
            entity="source",
            status="completed",
            changed=bool(
                deleted
            ),
            actor=actor,
            reason=reason,
            data={
                "requested":
                    len(values),

                "deleted":
                    deleted,
            },
        )


    except Exception as exc:

        return mutation_error(
            "delete_sources",
            entity="source",
            actor=actor,
            reason=reason,
            error=(
                type(exc).__name__
                + ":"
                + str(exc)
            ),
            data={
                "requested":
                    len(values),
            },
        )


def delete_all_sources_result(
    *,
    actor: str = "panel",
    reason: str = "delete_all_sources_requested",
):
    try:

        deleted = int(
            delete_all_sources()
        )


        return mutation_result(
            "delete_all_sources",
            entity="source",
            status="completed",
            changed=bool(
                deleted
            ),
            actor=actor,
            reason=reason,
            data={
                "deleted":
                    deleted,
            },
        )


    except Exception as exc:

        return mutation_error(
            "delete_all_sources",
            entity="source",
            actor=actor,
            reason=reason,
            error=(
                type(exc).__name__
                + ":"
                + str(exc)
            ),
        )
