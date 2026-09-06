from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import tarfile
import tempfile
import time

from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(
    "/var/lib/config-location"
)

LOCKROOT = (
    ROOT / "locks"
)

CONFIGS = (
    ROOT / "configs"
)

GCROOT = (
    ROOT
    / "integrity"
    / "lock-gc"
)

ARCHIVES = (
    GCROOT / "archives"
)

STATUS = (
    GCROOT / "status.json"
)


MIN_AGE_HOURS = int(
    os.environ.get(
        "CONFIG_LOCATION_LOCK_GC_MIN_AGE_HOURS",
        "24",
    )
)

MAX_PER_RUN = int(
    os.environ.get(
        "CONFIG_LOCATION_LOCK_GC_MAX",
        "5000",
    )
)


CONFIG_LOCK_RE = re.compile(
    r"^config-"
    r"(?P<config_id>[0-9a-fA-F]{64})"
    r"\.lock$"
)


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def sha256_file(
    path: Path,
) -> str:

    h = hashlib.sha256()

    with path.open("rb") as fh:

        while True:

            chunk = fh.read(
                1024 * 1024
            )

            if not chunk:
                break

            h.update(chunk)

    return h.hexdigest()


def atomic_json(
    path: Path,
    obj: dict[str, Any],
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
                obj,
                fh,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            fh.write("\n")
            fh.flush()
            os.fsync(
                fh.fileno()
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


def parse_config_lock(
    path: Path,
) -> str | None:

    match = CONFIG_LOCK_RE.fullmatch(
        path.name
    )

    if match is None:
        return None

    return (
        match.group(
            "config_id"
        )
        .lower()
    )


def config_exists(
    config_id: str,
) -> bool:

    return (
        CONFIGS
        / f"{config_id}.json"
    ).is_file()


def flock_is_free(
    path: Path,
) -> bool:

    """
    Non-destructive Linux flock probe.

    Does not truncate or rewrite the lock file.
    """

    try:

        fd = os.open(
            path,
            os.O_RDWR
            | os.O_CLOEXEC,
        )

    except FileNotFoundError:

        return False


    acquired = False

    try:

        try:

            fcntl.flock(
                fd,
                fcntl.LOCK_EX
                | fcntl.LOCK_NB,
            )

            acquired = True

        except BlockingIOError:

            return False


        return True

    finally:

        if acquired:

            try:

                fcntl.flock(
                    fd,
                    fcntl.LOCK_UN,
                )

            except Exception:
                pass

        os.close(fd)


def build_plan() -> dict[str, Any]:

    cutoff = (
        time.time()
        -
        MIN_AGE_HOURS
        * 3600
    )


    all_lock_files = [
        p
        for p in LOCKROOT.glob(
            "*.lock"
        )
        if p.is_file()
    ]


    recognized = 0
    unknown = 0

    protected_existing = 0
    protected_recent = 0
    protected_busy = 0

    disappeared = 0

    orphan_total = 0

    candidates: list[
        dict[str, Any]
    ] = []


    for path in sorted(
        all_lock_files
    ):

        config_id = parse_config_lock(
            path
        )


        if config_id is None:

            unknown += 1
            continue


        recognized += 1


        if config_exists(
            config_id
        ):

            protected_existing += 1
            continue


        orphan_total += 1


        try:

            st = path.stat()

        except FileNotFoundError:

            disappeared += 1
            continue


        if st.st_mtime >= cutoff:

            protected_recent += 1
            continue


        original_mtime = (
            st.st_mtime
        )

        original_size = (
            st.st_size
        )

        original_sha = sha256_file(
            path
        )


        if not flock_is_free(
            path
        ):

            protected_busy += 1
            continue


        # Re-check after lock probe.
        if config_exists(
            config_id
        ):

            protected_existing += 1
            continue


        try:

            st2 = path.stat()

        except FileNotFoundError:

            disappeared += 1
            continue


        if (
            st2.st_mtime
            != original_mtime
            or
            st2.st_size
            != original_size
        ):

            protected_recent += 1
            continue


        if (
            sha256_file(path)
            != original_sha
        ):

            protected_recent += 1
            continue


        candidates.append({
            "config_id":
                config_id,

            "filename":
                path.name,

            "path":
                str(path),

            "mtime":
                st2.st_mtime,

            "size":
                st2.st_size,

            "sha256":
                original_sha,
        })


    candidates.sort(
        key=lambda item: (
            item["mtime"],
            item["filename"],
        )
    )


    candidates = candidates[
        :MAX_PER_RUN
    ]


    return {
        "schema_version": 1,

        "stage":
            "FIX20.4C",

        "created_at":
            now_iso(),

        "schema":
            "config-<64hex-config-id>.lock",

        "policy": {
            "minimum_age_hours":
                MIN_AGE_HOURS,

            "max_per_run":
                MAX_PER_RUN,

            "unknown_locks_protected":
                True,

            "existing_config_protected":
                True,

            "recent_locks_protected":
                True,

            "busy_locks_protected":
                True,

            "archive_before_remove":
                True,

            "sha256_verify":
                True,

            "final_race_recheck":
                True,
        },

        "counts": {
            "all_lock_files":
                len(all_lock_files),

            "recognized_config_locks":
                recognized,

            "unknown_locks":
                unknown,

            "orphan_config_locks":
                orphan_total,

            "protected_existing_config":
                protected_existing,

            "protected_recent":
                protected_recent,

            "protected_busy":
                protected_busy,

            "disappeared":
                disappeared,

            "candidate_count":
                len(candidates),
        },

        "candidates":
            candidates,
    }


def archive_plan(
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
        / "orphan-config-locks.tar.gz"
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


            if (
                sha256_file(path)
                != item["sha256"]
            ):

                continue


            tf.add(
                path,
                arcname=(
                    "locks/"
                    + item[
                        "filename"
                    ]
                ),
                recursive=False,
            )


    sha_path = (
        run_dir
        / (
            "orphan-config-locks."
            "tar.gz.sha256"
        )
    )


    digest = sha256_file(
        archive
    )


    sha_path.write_text(
        (
            f"{digest}  "
            f"{archive.name}\n"
        ),
        encoding="utf-8",
    )


    return (
        archive,
        sha_path,
    )


def reconcile(
    plan: dict[str, Any],
) -> dict[str, Any]:

    cutoff = (
        time.time()
        -
        MIN_AGE_HOURS
        * 3600
    )


    removed = 0

    config_reappeared = 0
    recent_now = 0
    busy_now = 0
    changed_now = 0
    missing_now = 0


    for item in plan[
        "candidates"
    ]:

        config_id = (
            item["config_id"]
        )

        path = Path(
            item["path"]
        )


        if config_exists(
            config_id
        ):

            config_reappeared += 1
            continue


        if not path.is_file():

            missing_now += 1
            continue


        try:

            st = path.stat()

        except FileNotFoundError:

            missing_now += 1
            continue


        if st.st_mtime >= cutoff:

            recent_now += 1
            continue


        if (
            st.st_size
            != item["size"]
        ):

            changed_now += 1
            continue


        if (
            sha256_file(path)
            != item["sha256"]
        ):

            changed_now += 1
            continue


        if not flock_is_free(
            path
        ):

            busy_now += 1
            continue


        # Final config race check immediately
        # before unlink.
        if config_exists(
            config_id
        ):

            config_reappeared += 1
            continue


        if not path.is_file():

            missing_now += 1
            continue


        try:

            final_stat = path.stat()

        except FileNotFoundError:

            missing_now += 1
            continue


        if final_stat.st_mtime >= cutoff:

            recent_now += 1
            continue


        if (
            final_stat.st_size
            != item["size"]
        ):

            changed_now += 1
            continue


        if (
            sha256_file(path)
            != item["sha256"]
        ):

            changed_now += 1
            continue


        path.unlink()

        removed += 1


    return {
        "removed":
            removed,

        "config_reappeared":
            config_reappeared,

        "recent_now":
            recent_now,

        "busy_now":
            busy_now,

        "changed_now":
            changed_now,

        "missing_now":
            missing_now,
    }


def main() -> int:

    started = now_iso()

    ARCHIVES.mkdir(
        parents=True,
        exist_ok=True,
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


    archive, sha_path = (
        archive_plan(
            plan,
            run_dir,
        )
    )


    expected = (
        sha_path.read_text(
            encoding="utf-8"
        )
        .split()[0]
    )


    actual = sha256_file(
        archive
    )


    if actual != expected:

        raise RuntimeError(
            "lock archive SHA256 mismatch"
        )


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


    after = build_plan()


    status = {
        "schema_version": 1,

        "stage":
            "FIX20.4C",

        "started_at":
            started,

        "finished_at":
            now_iso(),

        "schema":
            plan["schema"],

        "policy":
            plan["policy"],

        "before":
            plan["counts"],

        "result":
            result,

        "after":
            after["counts"],

        "archive":
            str(archive),

        "archive_sha256_file":
            str(sha_path),

        "configs_deleted_by_gc":
            0,

        "health_deleted_by_gc":
            0,

        "unknown_locks_deleted":
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
