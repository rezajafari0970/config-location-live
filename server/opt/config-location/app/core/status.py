from __future__ import annotations

import json

from datetime import (
    datetime,
    timezone,
)

from pathlib import Path

from .events import (
    event_stats,
    list_events,
)


DATA = Path(
    "/var/lib/config-location"
)

CONFIG_DIR = (
    DATA / "configs"
)

SOURCE_FILE = (
    DATA
    / "sources"
    / "sources.json"
)

SNAPSHOT_DIR = (
    DATA
    / "source-snapshots"
)

TOMBSTONE_DIR = (
    DATA
    / "source-tombstones"
)

QUARANTINE_DIR = (
    DATA
    / "quarantine"
)

STATE_DIR = (
    DATA
    / "state"
)

SOURCE_REGISTRY_BLOCK = (
    STATE_DIR
    / "source-registry-blocked.json"
)

DELETION_JOURNAL = (
    STATE_DIR
    / "pending-source-deletion.json"
)

DELETION_JOURNAL_BLOCK = (
    STATE_DIR
    / "source-deletion-journal-blocked.json"
)


def now_iso():
    return datetime.now(
        timezone.utc
    ).isoformat()


def _read_json_safe(
    path: Path,
):
    try:

        obj = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

    except Exception:
        return None

    return obj


def _count_json(
    path: Path,
):
    if not path.exists():
        return 0

    return sum(
        1
        for item in path.rglob(
            "*.json"
        )
        if item.is_file()
    )


def _source_registry_status():

    result = {
        "exists":
            SOURCE_FILE.exists(),

        "blocked":
            SOURCE_REGISTRY_BLOCK.exists(),

        "valid":
            None,

        "source_count":
            None,

        "block_detail":
            (
                _read_json_safe(
                    SOURCE_REGISTRY_BLOCK
                )
                if SOURCE_REGISTRY_BLOCK.exists()
                else None
            ),
    }


    if not SOURCE_FILE.exists():

        if not result[
            "blocked"
        ]:

            result[
                "valid"
            ] = True

            result[
                "source_count"
            ] = 0

        return result


    obj = _read_json_safe(
        SOURCE_FILE
    )


    if (
        isinstance(
            obj,
            dict
        )
        and isinstance(
            obj.get(
                "sources"
            ),
            list
        )
    ):

        result[
            "valid"
        ] = True

        result[
            "source_count"
        ] = len(
            obj[
                "sources"
            ]
        )

    else:

        result[
            "valid"
        ] = False


    return result


def get_core_status(
    *,
    event_limit: int = 20,
):
    registry = (
        _source_registry_status()
    )


    deletion_journal = {
        "pending":
            DELETION_JOURNAL.exists(),

        "blocked":
            DELETION_JOURNAL_BLOCK.exists(),

        "pending_detail":
            (
                _read_json_safe(
                    DELETION_JOURNAL
                )
                if DELETION_JOURNAL.exists()
                else None
            ),

        "block_detail":
            (
                _read_json_safe(
                    DELETION_JOURNAL_BLOCK
                )
                if DELETION_JOURNAL_BLOCK.exists()
                else None
            ),
    }


    config_count = (
        sum(
            1
            for path in CONFIG_DIR.glob(
                "*.json"
            )
            if path.is_file()
        )
        if CONFIG_DIR.exists()
        else 0
    )


    snapshot_count = (
        sum(
            1
            for path in SNAPSHOT_DIR.glob(
                "*.json"
            )
            if path.is_file()
        )
        if SNAPSHOT_DIR.exists()
        else 0
    )


    tombstone_count = (
        sum(
            1
            for path in TOMBSTONE_DIR.glob(
                "*.json"
            )
            if path.is_file()
        )
        if TOMBSTONE_DIR.exists()
        else 0
    )


    quarantine_count = (
        _count_json(
            QUARANTINE_DIR
        )
    )


    problems = []


    if registry[
        "blocked"
    ]:

        problems.append(
            "source_registry_blocked"
        )


    if registry[
        "valid"
    ] is False:

        problems.append(
            "source_registry_invalid"
        )


    if deletion_journal[
        "blocked"
    ]:

        problems.append(
            "source_deletion_journal_blocked"
        )


    if deletion_journal[
        "pending"
    ]:

        problems.append(
            "source_deletion_pending"
        )


    return {
        "generated_at": now_iso(),

        "healthy":
            not bool(
                problems
            ),

        "problems":
            problems,

        "source_registry":
            registry,

        "configs": {
            "count":
                config_count,
        },

        "snapshots": {
            "count":
                snapshot_count,
        },

        "tombstones": {
            "count":
                tombstone_count,
        },

        "quarantine": {
            "json_files":
                quarantine_count,
        },

        "deletion_journal":
            deletion_journal,

        "events": {
            "stats":
                event_stats(),

            "recent":
                list_events(
                    limit=event_limit
                ),
        },
    }
