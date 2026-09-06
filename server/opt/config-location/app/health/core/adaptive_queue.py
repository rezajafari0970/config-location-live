from __future__ import annotations

import json
import os

from pathlib import Path

from .batch import (
    BatchJob,
)

from .scheduler import (
    mix_jobs_by_type,
)


QUEUE_VERSION = 1


def _atomic(
    path: Path,
    value: dict,
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    tmp = path.with_name(
        "." + path.name + ".tmp"
    )

    tmp.write_text(
        json.dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )

    tmp.chmod(
        0o600
    )

    os.replace(
        tmp,
        path,
    )


def load_queue(
    path: Path,
) -> list[str]:

    if not path.exists():
        return []

    try:

        obj = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

        if (
            obj.get("version")
            != QUEUE_VERSION
        ):
            return []

        values = obj.get(
            "queue",
            [],
        )

        if not isinstance(
            values,
            list,
        ):
            return []

        return [
            str(x)
            for x in values
        ]

    except Exception:
        return []


def save_queue(
    path: Path,
    queue: list[str],
) -> None:

    _atomic(
        path,
        {
            "version":
                QUEUE_VERSION,

            "queue":
                queue,
        },
    )


def reconcile_queue(
    *,
    existing_queue: list[str],
    jobs: list[BatchJob],
) -> list[str]:

    job_map = {
        job.config_id:
            job
        for job in jobs
    }


    current = []

    seen = set()


    # Preserve prior order for configs that
    # still exist.
    for config_id in existing_queue:

        if (
            config_id in job_map
            and config_id not in seen
        ):

            current.append(
                config_id
            )

            seen.add(
                config_id
            )


    # New configs enter through the same fair
    # type-mixing policy.
    new_jobs = [
        job
        for job in jobs
        if job.config_id not in seen
    ]


    mixed_new = (
        mix_jobs_by_type(
            new_jobs
        )
    )


    for job in mixed_new:

        current.append(
            job.config_id
        )

        seen.add(
            job.config_id
        )


    if len(current) != len(job_map):
        raise RuntimeError(
            "queue reconciliation mismatch"
        )


    return current


def peek(
    queue: list[str],
    count: int,
) -> list[str]:

    return queue[
        :max(
            0,
            count,
        )
    ]


def commit_completed(
    *,
    queue: list[str],
    completed_ids: list[str],
) -> list[str]:

    if not completed_ids:
        return queue


    count = len(
        completed_ids
    )


    expected = (
        queue[:count]
    )


    if expected != completed_ids:

        raise RuntimeError(
            "queue commit order mismatch"
        )


    return (
        queue[count:]
        + completed_ids
    )
