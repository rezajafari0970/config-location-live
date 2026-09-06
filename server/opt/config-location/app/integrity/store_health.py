from __future__ import annotations

import json
import os
import tempfile

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_CONFIG_DIR = Path(
    "/var/lib/config-location/configs"
)

DEFAULT_HEALTH_LATEST_DIR = Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

DEFAULT_REPORT_PATH = Path(
    "/var/lib/config-location/"
    "integrity/"
    "store-health-latest.json"
)


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def _atomic_json(
    path: Path,
    value: dict[str, Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd, tmp_name = tempfile.mkstemp(
        dir=str(path.parent),
        prefix=f".{path.name}.",
        suffix=".tmp",
    )

    tmp = Path(tmp_name)

    try:
        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as fh:

            json.dump(
                value,
                fh,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())

        os.chmod(
            tmp,
            0o640,
        )

        os.replace(
            tmp,
            path,
        )

        dir_fd = os.open(
            str(path.parent),
            os.O_DIRECTORY,
        )

        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)

    finally:
        tmp.unlink(
            missing_ok=True
        )


def _read_json(
    path: Path,
) -> tuple[
    dict[str, Any] | None,
    str | None,
]:

    try:
        value = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

    except Exception as exc:
        return (
            None,
            f"{type(exc).__name__}: {exc}",
        )

    if not isinstance(
        value,
        dict,
    ):
        return (
            None,
            "root_not_object",
        )

    return (
        value,
        None,
    )


def _config_id_from_record(
    path: Path,
    value: dict[str, Any],
) -> str:

    record_id = str(
        value.get(
            "id",
            ""
        )
        or ""
    ).strip()

    if record_id:
        return record_id

    return path.stem


def _health_config_id(
    path: Path,
    value: dict[str, Any],
) -> str:

    return str(
        value.get(
            "config_id",
            ""
        )
        or ""
    ).strip()


def build_store_health_integrity(
    *,
    config_dir: Path = DEFAULT_CONFIG_DIR,
    health_latest_dir: Path = DEFAULT_HEALTH_LATEST_DIR,
) -> dict[str, Any]:

    generated_at = now_iso()

    config_ids: set[str] = set()
    health_ids: set[str] = set()

    invalid_config_files: list[dict[str, str]] = []
    invalid_health_files: list[dict[str, str]] = []

    config_filename_mismatches: list[dict[str, str]] = []
    health_filename_mismatches: list[dict[str, str]] = []

    duplicate_config_ids: list[str] = []
    duplicate_health_ids: list[str] = []

    seen_config: set[str] = set()
    seen_health: set[str] = set()


    # ---------------------------------------------------------
    # Production config store
    # ---------------------------------------------------------

    for path in sorted(
        config_dir.glob(
            "*.json"
        )
    ):

        value, error = _read_json(
            path
        )

        if error is not None:

            invalid_config_files.append({
                "file": path.name,
                "error": error,
            })

            continue


        assert value is not None


        config_id = _config_id_from_record(
            path,
            value,
        )


        if not config_id:

            invalid_config_files.append({
                "file": path.name,
                "error": "missing_config_id",
            })

            continue


        if config_id in seen_config:
            duplicate_config_ids.append(
                config_id
            )

        seen_config.add(
            config_id
        )

        config_ids.add(
            config_id
        )


        if path.stem != config_id:

            config_filename_mismatches.append({
                "file": path.name,
                "record_id": config_id,
            })


    # ---------------------------------------------------------
    # Latest health store
    # ---------------------------------------------------------

    for path in sorted(
        health_latest_dir.glob(
            "*.json"
        )
    ):

        value, error = _read_json(
            path
        )

        if error is not None:

            invalid_health_files.append({
                "file": path.name,
                "error": error,
            })

            continue


        assert value is not None


        config_id = _health_config_id(
            path,
            value,
        )


        if not config_id:

            invalid_health_files.append({
                "file": path.name,
                "error": "missing_config_id",
            })

            continue


        if config_id in seen_health:
            duplicate_health_ids.append(
                config_id
            )

        seen_health.add(
            config_id
        )

        health_ids.add(
            config_id
        )


        # Current config fingerprints are SHA-like and
        # JsonHealthResultStore._safe_name preserves them.
        # This detects corruption / unexpected naming.
        if path.stem != config_id:

            health_filename_mismatches.append({
                "file": path.name,
                "config_id": config_id,
            })


    # ---------------------------------------------------------
    # Referential sets
    # ---------------------------------------------------------

    orphans = sorted(
        health_ids
        -
        config_ids
    )

    configs_without_health = sorted(
        config_ids
        -
        health_ids
    )

    matched = sorted(
        config_ids
        &
        health_ids
    )


    problem_count = (
        len(orphans)
        +
        len(configs_without_health)
        +
        len(invalid_config_files)
        +
        len(invalid_health_files)
        +
        len(config_filename_mismatches)
        +
        len(health_filename_mismatches)
        +
        len(set(duplicate_config_ids))
        +
        len(set(duplicate_health_ids))
    )


    # Missing Health is not treated as corruption.
    # A newly fetched config legitimately may not have been
    # tested yet. It is therefore surfaced separately.
    hard_problem_count = (
        len(orphans)
        +
        len(invalid_config_files)
        +
        len(invalid_health_files)
        +
        len(config_filename_mismatches)
        +
        len(health_filename_mismatches)
        +
        len(set(duplicate_config_ids))
        +
        len(set(duplicate_health_ids))
    )


    if hard_problem_count == 0:

        state = "healthy"

    else:

        state = "inconsistent"


    report: dict[str, Any] = {

        "schema_version": 1,

        "stage":
            "FIX20.1",

        "generated_at":
            generated_at,

        "state":
            state,

        "read_only":
            True,

        "paths": {
            "config_dir":
                str(config_dir),

            "health_latest_dir":
                str(
                    health_latest_dir
                ),
        },

        "counts": {
            "configs":
                len(config_ids),

            "health_latest":
                len(health_ids),

            "matched":
                len(matched),

            "orphan_health":
                len(orphans),

            "configs_without_health":
                len(
                    configs_without_health
                ),

            "invalid_config_files":
                len(
                    invalid_config_files
                ),

            "invalid_health_files":
                len(
                    invalid_health_files
                ),

            "config_filename_mismatches":
                len(
                    config_filename_mismatches
                ),

            "health_filename_mismatches":
                len(
                    health_filename_mismatches
                ),

            "duplicate_config_ids":
                len(
                    set(
                        duplicate_config_ids
                    )
                ),

            "duplicate_health_ids":
                len(
                    set(
                        duplicate_health_ids
                    )
                ),

            "problem_count":
                problem_count,

            "hard_problem_count":
                hard_problem_count,
        },

        "orphan_health_ids":
            orphans,

        "configs_without_health_ids":
            configs_without_health,

        "invalid_config_files":
            invalid_config_files,

        "invalid_health_files":
            invalid_health_files,

        "config_filename_mismatches":
            config_filename_mismatches,

        "health_filename_mismatches":
            health_filename_mismatches,

        "duplicate_config_ids":
            sorted(
                set(
                    duplicate_config_ids
                )
            ),

        "duplicate_health_ids":
            sorted(
                set(
                    duplicate_health_ids
                )
            ),
    }


    return report


def write_store_health_integrity(
    *,
    report_path: Path = DEFAULT_REPORT_PATH,
    config_dir: Path = DEFAULT_CONFIG_DIR,
    health_latest_dir: Path = DEFAULT_HEALTH_LATEST_DIR,
) -> dict[str, Any]:

    report = build_store_health_integrity(
        config_dir=config_dir,
        health_latest_dir=(
            health_latest_dir
        ),
    )

    _atomic_json(
        report_path,
        report,
    )

    return report
