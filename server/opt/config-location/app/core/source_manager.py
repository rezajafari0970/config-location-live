from __future__ import annotations

import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from .storage import read_json, atomic_write_json


from app.core.config_store import (
    detach_source_from_configs,
    detach_sources_from_configs,
    delete_all_configs,
)



SOURCE_FILE = Path("/var/lib/config-location/sources/sources.json")


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

    port = parsed.port

    if port:
        default = (
            scheme == "http" and port == 80
        ) or (
            scheme == "https" and port == 443
        )

        netloc = hostname if default else f"{hostname}:{port}"
    else:
        netloc = hostname

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
    data = read_json(SOURCE_FILE, {"version": 1, "sources": []})

    if not isinstance(data, dict):
        data = {"version": 1, "sources": []}

    if not isinstance(data.get("sources"), list):
        data["sources"] = []

    return data


def _save(data):
    atomic_write_json(SOURCE_FILE, data)


def list_sources():
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


def delete_source(source_id: str):
    """
    Delete one source.

    Config ownership is updated automatically:
    - configs belonging only to this source are deleted
    - shared configs remain with their other source_ids
    """

    source_id = str(
        source_id
    )

    data = _load()

    old_len = len(
        data["sources"]
    )

    data["sources"] = [
        source
        for source in data["sources"]
        if str(
            source.get("id")
        ) != source_id
    ]

    if len(
        data["sources"]
    ) == old_len:
        return False

    _save(
        data
    )

    detach_source_from_configs(
        source_id
    )

    return True



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


def delete_sources(source_ids):
    """
    Delete multiple sources atomically.

    Configs shared with surviving sources are kept.
    Orphan configs are deleted.
    """

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
            source.get("id")
        )
        for source in data["sources"]
    }

    actual_ids = (
        ids
        & existing_ids
    )

    if not actual_ids:
        return 0

    data["sources"] = [
        source
        for source in data["sources"]
        if str(
            source.get("id")
        ) not in actual_ids
    ]

    _save(
        data
    )

    detach_sources_from_configs(
        actual_ids
    )

    return len(
        actual_ids
    )



def delete_all_sources():
    """
    Delete all configured sources.

    With no sources remaining, every collected
    config becomes orphaned and is removed.
    """

    data = _load()

    deleted = len(
        data["sources"]
    )

    data["sources"] = []

    _save(
        data
    )

    delete_all_configs()

    return deleted

