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

CONFIG_QUARANTINE_DIR = (
    QUARANTINE_DIR
    / "corrupt-configs"
)

SNAPSHOT_QUARANTINE_DIR = (
    QUARANTINE_DIR
    / "source-snapshots"
)

RUNTIME_QUARANTINE_DIR = (
    QUARANTINE_DIR
    / "source-runtime"
)

SOURCE_REGISTRY_QUARANTINE_DIR = (
    QUARANTINE_DIR
    / "source-registry"
)

DELETION_JOURNAL_QUARANTINE_DIR = (
    QUARANTINE_DIR
    / "source-deletion-journal"
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


def _count_files(
    path: Path,
    pattern: str = "*",
):
    if not path.exists():
        return 0

    return sum(
        1
        for item in path.glob(
            pattern
        )
        if item.is_file()
    )


def _count_incidents(
    path: Path,
):
    """
    Count quarantined payload incidents, excluding
    sidecar .meta.json evidence files.
    """

    if not path.exists():
        return 0


    count = 0


    for item in path.iterdir():

        if not item.is_file():
            continue


        if item.name.endswith(
            ".meta.json"
        ):
            continue


        count += 1


    return count


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


def _quarantine_status():

    result = {
        "config_incidents":
            _count_incidents(
                CONFIG_QUARANTINE_DIR
            ),

        "snapshot_incidents":
            _count_incidents(
                SNAPSHOT_QUARANTINE_DIR
            ),

        "runtime_incidents":
            _count_incidents(
                RUNTIME_QUARANTINE_DIR
            ),

        "source_registry_incidents":
            _count_incidents(
                SOURCE_REGISTRY_QUARANTINE_DIR
            ),

        "deletion_journal_incidents":
            _count_incidents(
                DELETION_JOURNAL_QUARANTINE_DIR
            ),
    }


    result[
        "total_incidents"
    ] = sum(
        result.values()
    )


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


    quarantine = (
        _quarantine_status()
    )


    config_count = (
        _count_files(
            CONFIG_DIR,
            "*.json",
        )
    )


    snapshot_count = (
        _count_files(
            SNAPSHOT_DIR,
            "*.json",
        )
    )


    tombstone_count = (
        _count_files(
            TOMBSTONE_DIR,
            "*.json",
        )
    )


    events = {
        "stats":
            event_stats(),

        "recent":
            list_events(
                limit=event_limit
            ),
    }


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


    if quarantine[
        "config_incidents"
    ] > 0:

        problems.append(
            "config_quarantine_present"
        )


    if quarantine[
        "snapshot_incidents"
    ] > 0:

        problems.append(
            "snapshot_quarantine_present"
        )


    if quarantine[
        "runtime_incidents"
    ] > 0:

        problems.append(
            "runtime_quarantine_present"
        )


    if quarantine[
        "source_registry_incidents"
    ] > 0:

        problems.append(
            "source_registry_quarantine_present"
        )


    if quarantine[
        "deletion_journal_incidents"
    ] > 0:

        problems.append(
            "deletion_journal_quarantine_present"
        )


    return {
        "generated_at":
            now_iso(),

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

        "quarantine":
            quarantine,

        "deletion_journal":
            deletion_journal,

        "events":
            events,
    }
