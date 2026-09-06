from __future__ import annotations

import hashlib
import json
import os
import shutil
import tempfile

from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DATA = Path(
    "/var/lib/config-location"
)

CONFIG_DIR = (
    DATA / "configs"
)

LATEST_DIR = (
    DATA
    / "health-results"
    / "latest"
)

ROOT = (
    DATA
    / "integrity"
    / "referential-guard"
)

ARCHIVE_ROOT = (
    ROOT / "archive"
)

STATUS_PATH = (
    ROOT / "status.json"
)


def now() -> datetime:
    return datetime.now(
        timezone.utc
    )


def now_iso() -> str:
    return now().isoformat()


def _sha256(
    path: Path,
) -> str:

    h = hashlib.sha256()

    with path.open("rb") as f:

        while True:

            chunk = f.read(
                1024 * 1024
            )

            if not chunk:
                break

            h.update(chunk)

    return h.hexdigest()


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

        os.chmod(
            tmp,
            0o640,
        )

        os.replace(
            tmp,
            path,
        )

    finally:

        tmp.unlink(
            missing_ok=True
        )


def _archive_dir(
    config_id: str,
) -> Path:

    t = now()

    return (
        ARCHIVE_ROOT
        / t.strftime("%Y")
        / t.strftime("%m")
        / t.strftime("%d")
        / config_id
    )


def archive_latest_before_config_delete(
    config_id: str,
    *,
    reason: str,
) -> dict[str, Any]:

    """
    Called immediately before deleting a Config record.

    It never deletes the Config itself.

    If Latest Health exists:
      1. copy to immutable archive location
      2. verify SHA256
      3. re-check latest did not change
      4. remove only that exact latest result

    A later in-flight health job can still create a new
    orphan. The periodic sweep handles that case.
    """

    config_id = str(
        config_id
        or ""
    ).strip()

    result: dict[str, Any] = {
        "config_id":
            config_id,

        "reason":
            reason,

        "archived":
            False,

        "latest_removed":
            False,

        "latest_missing":
            False,

        "latest_changed":
            False,
    }


    if not config_id:

        result["error"] = (
            "empty_config_id"
        )

        return result


    latest = (
        LATEST_DIR
        / f"{config_id}.json"
    )


    if not latest.is_file():

        result[
            "latest_missing"
        ] = True

        return result


    original_sha = _sha256(
        latest
    )


    target_dir = _archive_dir(
        config_id
    )

    target_dir.mkdir(
        parents=True,
        exist_ok=True,
    )


    stamp = now().strftime(
        "%H%M%S-%f"
    )


    archived = (
        target_dir
        / (
            f"{stamp}-"
            f"{original_sha[:16]}.json"
        )
    )


    shutil.copy2(
        latest,
        archived,
    )


    archived_sha = _sha256(
        archived
    )


    if archived_sha != original_sha:

        archived.unlink(
            missing_ok=True
        )

        raise RuntimeError(
            "referential guard archive "
            "sha256 mismatch"
        )


    metadata = {
        "schema_version": 1,

        "stage":
            "FIX20.2C",

        "config_id":
            config_id,

        "reason":
            reason,

        "archived_at":
            now_iso(),

        "sha256":
            original_sha,

        "source_latest":
            str(latest),

        "archive_file":
            str(archived),
    }


    _atomic_json(
        archived.with_suffix(
            ".meta.json"
        ),
        metadata,
    )


    result["archived"] = True
    result["archive_file"] = str(
        archived
    )

    result["sha256"] = (
        original_sha
    )


    # Latest may have changed while we copied it.
    if not latest.is_file():

        return result


    current_sha = _sha256(
        latest
    )


    if current_sha != original_sha:

        result[
            "latest_changed"
        ] = True

        return result


    latest.unlink()

    result[
        "latest_removed"
    ] = True

    return result


def reconcile_one_orphan(
    config_id: str,
    *,
    reason: str = (
        "periodic_orphan_sweep"
    ),
) -> dict[str, Any]:

    config_id = str(
        config_id
        or ""
    ).strip()


    config = (
        CONFIG_DIR
        / f"{config_id}.json"
    )


    if config.is_file():

        return {
            "config_id":
                config_id,

            "skipped":
                "config_exists",
        }


    latest = (
        LATEST_DIR
        / f"{config_id}.json"
    )


    if not latest.is_file():

        return {
            "config_id":
                config_id,

            "skipped":
                "latest_missing",
        }


    # archive_latest... does not examine Config because
    # it is also used by the Config deletion path.
    # Re-check immediately before calling it.
    if config.is_file():

        return {
            "config_id":
                config_id,

            "skipped":
                "config_reappeared",
        }


    result = (
        archive_latest_before_config_delete(
            config_id,
            reason=reason,
        )
    )


    # If config appeared while archive was being made,
    # preserve the active relation if possible.
    if config.is_file():

        result[
            "config_reappeared_after_archive"
        ] = True


    return result


def sweep_orphans(
    *,
    max_items: int = 5000,
) -> dict[str, Any]:

    started = now_iso()

    config_ids = {
        p.stem
        for p
        in CONFIG_DIR.glob(
            "*.json"
        )
    }

    latest_ids = {
        p.stem
        for p
        in LATEST_DIR.glob(
            "*.json"
        )
    }

    candidates = sorted(
        latest_ids
        -
        config_ids
    )[:max_items]


    archived = 0
    removed = 0
    skipped = 0
    changed = 0
    errors: list[dict[str, str]] = []


    for config_id in candidates:

        try:

            result = reconcile_one_orphan(
                config_id
            )

        except Exception as exc:

            errors.append({
                "config_id":
                    config_id,

                "error":
                    (
                        f"{type(exc).__name__}: "
                        f"{exc}"
                    ),
            })

            continue


        if result.get(
            "archived"
        ):
            archived += 1

        if result.get(
            "latest_removed"
        ):
            removed += 1

        elif result.get(
            "latest_changed"
        ):
            changed += 1

        else:
            skipped += 1


    # Fresh post-sweep count.
    post_configs = {
        p.stem
        for p
        in CONFIG_DIR.glob(
            "*.json"
        )
    }

    post_latest = {
        p.stem
        for p
        in LATEST_DIR.glob(
            "*.json"
        )
    }

    remaining = sorted(
        post_latest
        -
        post_configs
    )


    status = {
        "schema_version": 1,

        "stage":
            "FIX20.2C",

        "started_at":
            started,

        "finished_at":
            now_iso(),

        "candidates":
            len(candidates),

        "archived":
            archived,

        "latest_removed":
            removed,

        "skipped":
            skipped,

        "changed":
            changed,

        "errors":
            errors,

        "error_count":
            len(errors),

        "remaining_orphans":
            len(remaining),

        "remaining_sample":
            remaining[:20],
    }


    _atomic_json(
        STATUS_PATH,
        status,
    )

    return status


def main() -> int:

    result = sweep_orphans()

    print(
        json.dumps(
            result,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
    )

    return (
        1
        if result[
            "error_count"
        ]
        else 0
    )


if __name__ == "__main__":

    raise SystemExit(
        main()
    )
