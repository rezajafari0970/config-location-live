from __future__ import annotations

import hashlib
import json
import os
import tarfile
import tempfile
import time

from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(
    "/var/lib/config-location"
)

HISTORY = (
    ROOT
    / "health-results"
    / "history"
)

LATEST = (
    ROOT
    / "health-results"
    / "latest"
)

GCROOT = (
    ROOT
    / "integrity"
    / "health-history-gc"
)

ARCHIVES = (
    GCROOT
    / "archives"
)

STATUS = (
    GCROOT
    / "status.json"
)


RETENTION_HOURS = int(
    os.environ.get(
        "CONFIG_LOCATION_HISTORY_RETENTION_HOURS",
        "72",
    )
)

MIN_KEEP_PER_CONFIG = int(
    os.environ.get(
        "CONFIG_LOCATION_HISTORY_MIN_KEEP",
        "20",
    )
)

MAX_DELETE_PER_RUN = int(
    os.environ.get(
        "CONFIG_LOCATION_HISTORY_GC_MAX",
        "10000",
    )
)


def iso_now() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def sha256_file(
    path: Path,
) -> str:

    h = hashlib.sha256()

    with path.open("rb") as f:

        while True:

            b = f.read(
                1024 * 1024
            )

            if not b:
                break

            h.update(b)

    return h.hexdigest()


def atomic_json(
    path: Path,
    obj: dict[str, Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd, name = tempfile.mkstemp(
        dir=str(path.parent),
        prefix=f".{path.name}.",
        suffix=".tmp",
    )

    tmp = Path(name)

    try:

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as f:

            json.dump(
                obj,
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


def read_config_id(
    path: Path,
) -> tuple[
    str | None,
    str | None,
]:

    try:

        obj = json.loads(
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
        obj,
        dict,
    ):

        return (
            None,
            "root_not_object",
        )


    config_id = str(
        obj.get(
            "config_id",
            ""
        )
        or ""
    ).strip()


    if not config_id:

        return (
            None,
            "missing_config_id",
        )


    return (
        config_id,
        None,
    )


def build_plan() -> dict[str, Any]:

    now_ts = time.time()

    cutoff = (
        now_ts
        -
        RETENTION_HOURS
        * 3600
    )


    groups: dict[
        str,
        list[tuple[float, Path]]
    ] = defaultdict(list)


    invalid: list[
        dict[str, str]
    ] = []


    files = sorted(
        HISTORY.rglob(
            "*.json"
        )
    )


    for path in files:

        if not path.is_file():
            continue

        config_id, error = (
            read_config_id(
                path
            )
        )


        if error is not None:

            invalid.append({
                "file":
                    str(path),

                "error":
                    error,
            })

            continue


        assert config_id is not None


        try:
            mtime = (
                path.stat().st_mtime
            )

        except FileNotFoundError:
            continue


        groups[
            config_id
        ].append(
            (
                mtime,
                path,
            )
        )


    candidates: list[
        dict[str, Any]
    ] = []


    protected_recent = 0
    protected_minimum = 0


    for config_id, entries in groups.items():

        entries.sort(
            key=lambda x: x[0],
            reverse=True,
        )


        protected_paths = {
            path
            for _mtime, path
            in entries[
                :MIN_KEEP_PER_CONFIG
            ]
        }


        for index, (
            mtime,
            path,
        ) in enumerate(
            entries
        ):

            if path in protected_paths:

                protected_minimum += 1
                continue


            if mtime >= cutoff:

                protected_recent += 1
                continue


            try:

                st = path.stat()

            except FileNotFoundError:
                continue


            candidates.append({
                "config_id":
                    config_id,

                "path":
                    str(path),

                "relative":
                    str(
                        path.relative_to(
                            HISTORY
                        )
                    ),

                "mtime":
                    mtime,

                "size":
                    st.st_size,

                "sha256":
                    sha256_file(
                        path
                    ),
            })


    # Delete oldest first.
    candidates.sort(
        key=lambda x: (
            x["mtime"],
            x["path"],
        )
    )


    candidates = candidates[
        :MAX_DELETE_PER_RUN
    ]


    return {
        "schema_version": 1,

        "stage":
            "FIX20.3",

        "created_at":
            iso_now(),

        "policy": {
            "retention_hours":
                RETENTION_HOURS,

            "min_keep_per_config":
                MIN_KEEP_PER_CONFIG,

            "max_delete_per_run":
                MAX_DELETE_PER_RUN,
        },

        "counts": {
            "history_files_seen":
                len(files),

            "configs_seen":
                len(groups),

            "invalid_files":
                len(invalid),

            "protected_recent":
                protected_recent,

            "protected_minimum":
                protected_minimum,

            "candidate_count":
                len(candidates),
        },

        "invalid_files":
            invalid,

        "candidates":
            candidates,
    }


def archive_candidates(
    plan: dict[str, Any],
    run_dir: Path,
) -> tuple[
    Path,
    Path,
]:

    run_dir.mkdir(
        parents=True,
        exist_ok=True,
    )


    manifest = (
        run_dir
        / "manifest.json"
    )


    atomic_json(
        manifest,
        plan,
    )


    archive = (
        run_dir
        / "health-history.tar.gz"
    )


    with tarfile.open(
        archive,
        "w:gz",
    ) as tf:

        tf.add(
            manifest,
            arcname="manifest.json",
        )


        for item in plan[
            "candidates"
        ]:

            path = Path(
                item["path"]
            )


            if not path.is_file():
                continue


            # Verify bytes before placing in archive.
            current_sha = sha256_file(
                path
            )


            if (
                current_sha
                != item["sha256"]
            ):

                continue


            tf.add(
                path,
                arcname=(
                    "history/"
                    + item[
                        "relative"
                    ]
                ),
                recursive=False,
            )


    sha = (
        run_dir
        / "health-history.tar.gz.sha256"
    )


    digest = sha256_file(
        archive
    )


    sha.write_text(
        (
            f"{digest}  "
            f"{archive.name}\n"
        ),
        encoding="utf-8",
    )


    return (
        archive,
        sha,
    )


def reconcile(
    plan: dict[str, Any],
) -> dict[str, Any]:

    removed = 0

    changed = 0
    missing = 0
    recent_now = 0

    cutoff = (
        time.time()
        -
        RETENTION_HOURS
        * 3600
    )


    for item in plan[
        "candidates"
    ]:

        path = Path(
            item["path"]
        )


        if not path.is_file():

            missing += 1
            continue


        try:
            st = path.stat()

        except FileNotFoundError:

            missing += 1
            continue


        # Never remove something that somehow became
        # "recent" after planning.
        if st.st_mtime >= cutoff:

            recent_now += 1
            continue


        current_sha = sha256_file(
            path
        )


        if (
            current_sha
            != item["sha256"]
        ):

            changed += 1
            continue


        path.unlink()

        removed += 1


    return {
        "removed":
            removed,

        "changed":
            changed,

        "missing":
            missing,

        "recent_now":
            recent_now,
    }


def latest_fingerprint() -> dict[str, Any]:

    files = [
        p
        for p
        in LATEST.glob(
            "*.json"
        )
        if p.is_file()
    ]


    total_size = sum(
        p.stat().st_size
        for p in files
    )


    return {
        "count":
            len(files),

        "total_size":
            total_size,
    }


def main() -> int:

    started = iso_now()

    ARCHIVES.mkdir(
        parents=True,
        exist_ok=True,
    )


    latest_before = (
        latest_fingerprint()
    )


    plan = build_plan()


    stamp = datetime.now(
        timezone.utc
    ).strftime(
        "%Y%m%d-%H%M%S"
    )


    run_dir = (
        ARCHIVES
        / stamp
    )


    archive, sha = (
        archive_candidates(
            plan,
            run_dir,
        )
    )


    # Verify archive checksum from disk.
    archive_sha = (
        sha256_file(
            archive
        )
    )


    expected = (
        sha.read_text(
            encoding="utf-8"
        )
        .split()[0]
    )


    if archive_sha != expected:

        raise RuntimeError(
            "archive SHA256 verification failed"
        )


    # Verify tar can be opened.
    with tarfile.open(
        archive,
        "r:gz",
    ) as tf:

        names = tf.getnames()

        if (
            "manifest.json"
            not in names
        ):

            raise RuntimeError(
                "manifest missing from archive"
            )


    result = reconcile(
        plan
    )


    latest_after = (
        latest_fingerprint()
    )


    if (
        latest_before
        != latest_after
    ):

        # Latest is live and may legitimately change due
        # to Health worker. The GC itself never references
        # or deletes Latest, therefore this is informational.
        latest_changed_during_gc = True

    else:

        latest_changed_during_gc = False


    history_after = len(
        list(
            HISTORY.rglob(
                "*.json"
            )
        )
    )


    status = {
        "schema_version": 1,

        "stage":
            "FIX20.3",

        "started_at":
            started,

        "finished_at":
            iso_now(),

        "policy":
            plan["policy"],

        "history_before":
            plan[
                "counts"
            ][
                "history_files_seen"
            ],

        "history_after":
            history_after,

        "candidate_count":
            plan[
                "counts"
            ][
                "candidate_count"
            ],

        "removed":
            result[
                "removed"
            ],

        "changed":
            result[
                "changed"
            ],

        "missing":
            result[
                "missing"
            ],

        "recent_now":
            result[
                "recent_now"
            ],

        "invalid_files":
            plan[
                "counts"
            ][
                "invalid_files"
            ],

        "archive":
            str(archive),

        "archive_sha256_file":
            str(sha),

        "latest_before":
            latest_before,

        "latest_after":
            latest_after,

        "latest_changed_during_gc":
            latest_changed_during_gc,

        "latest_deleted_by_gc":
            0,
    }


    atomic_json(
        STATUS,
        status,
    )


    print(
        json.dumps(
            status,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
    )


    return 0


if __name__ == "__main__":

    raise SystemExit(
        main()
    )
