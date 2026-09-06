from __future__ import annotations

import json
import os

from pathlib import Path

from .batch import BatchJob
from .scheduler import (
    mix_jobs_by_type,
)


VERSION = 3


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
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    tmp.chmod(0o600)

    os.replace(
        tmp,
        path,
    )


def empty_state() -> dict:

    return {
        "version": VERSION,
        "queue": [],
        "leases": [],
        "generation": 0,
    }


def load_state(
    path: Path,
) -> dict:

    if not path.exists():
        return empty_state()

    try:

        obj = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

    except Exception:
        return empty_state()


    queue = obj.get(
        "queue",
        [],
    )

    leases = obj.get(
        "leases",
        [],
    )


    if not isinstance(queue, list):
        queue = []

    if not isinstance(leases, list):
        leases = []


    queue = [
        str(x)
        for x in queue
    ]

    leases = [
        str(x)
        for x in leases
    ]


    # Process restart/crash recovery:
    # no worker from the previous process can
    # still own these leases. Put them back at
    # the HEAD so they are retried before later
    # queue members.
    recovered = []

    seen = set()

    for cid in leases + queue:

        if cid in seen:
            continue

        seen.add(cid)
        recovered.append(cid)


    return {
        "version": VERSION,

        "queue": recovered,

        "leases": [],

        "generation": int(
            obj.get(
                "generation",
                0,
            )
        ),
    }


def save_state(
    path: Path,
    state: dict,
) -> None:

    _atomic(
        path,
        state,
    )


def reconcile(
    *,
    state: dict,
    jobs: list[BatchJob],
) -> dict:
    """
    Reconcile a LIVE Store without invalidating
    in-flight leases.

    Critical rule:
    A config may disappear from Store while its
    health job is running. Its lease MUST remain
    until that job completes.

    Queue members, however, must reflect only
    configs that currently exist.
    """

    job_map = {
        job.config_id:
            job
        for job in jobs
    }

    valid = set(
        job_map
    )


    leases = []

    leased_seen = set()


    # IMPORTANT:
    # preserve ALL current in-process leases,
    # even when their source disappeared from
    # the live Store.
    for cid in state.get(
        "leases",
        [],
    ):

        cid = str(cid)

        if cid in leased_seen:
            continue

        leased_seen.add(cid)
        leases.append(cid)


    queue = []

    seen = set(
        leases
    )


    # Existing queue entries remain only if the
    # config still exists.
    for cid in state.get(
        "queue",
        [],
    ):

        cid = str(cid)

        if (
            cid in valid
            and cid not in seen
        ):

            queue.append(cid)
            seen.add(cid)


    # Any newly fetched configs join using fair
    # type mixing.
    new_jobs = [
        job
        for job in jobs
        if job.config_id
        not in seen
    ]


    for job in mix_jobs_by_type(
        new_jobs
    ):

        queue.append(
            job.config_id
        )

        seen.add(
            job.config_id
        )


    # Every current Store config must be either
    # queued or leased.
    represented_valid = (
        set(queue)
        | (
            set(leases)
            & valid
        )
    )


    if represented_valid != valid:

        missing = (
            valid
            - represented_valid
        )

        extra = (
            represented_valid
            - valid
        )

        raise RuntimeError(
            "live queue reconciliation mismatch "
            f"missing={len(missing)} "
            f"extra={len(extra)}"
        )


    if len(
        queue + leases
    ) != len(
        set(
            queue + leases
        )
    ):

        raise RuntimeError(
            "duplicate live queue member"
        )


    return {
        "version": VERSION,

        "queue": queue,

        "leases": leases,

        "generation": int(
            state.get(
                "generation",
                0,
            )
        ) + 1,
    }


def lease_next(
    state: dict,
) -> str | None:

    queue = state[
        "queue"
    ]

    if not queue:
        return None


    cid = queue.pop(0)


    if cid in state[
        "leases"
    ]:

        raise RuntimeError(
            "duplicate lease"
        )


    state[
        "leases"
    ].append(
        cid
    )


    return cid


def finish_lease(
    *,
    state: dict,
    config_id: str,
    still_exists: bool,
) -> None:
    """
    Complete one in-flight job.

    If its source still exists, rotate it to the
    tail for the next health cycle.

    If Fetcher deleted it while it was running,
    simply retire the lease.
    """

    try:

        state[
            "leases"
        ].remove(
            config_id
        )

    except ValueError:

        raise RuntimeError(
            "completed job not leased"
        )


    if (
        still_exists
        and config_id
        not in state[
            "queue"
        ]
    ):

        state[
            "queue"
        ].append(
            config_id
        )


def requeue_lease(
    *,
    state: dict,
    config_id: str,
    still_exists: bool,
) -> None:

    try:

        state[
            "leases"
        ].remove(
            config_id
        )

    except ValueError:

        raise RuntimeError(
            "retry job not leased"
        )


    if (
        still_exists
        and config_id
        not in state[
            "queue"
        ]
    ):

        # Infrastructure uncertainty should be
        # retried soon, not after a whole cycle.
        state[
            "queue"
        ].insert(
            0,
            config_id,
        )


def assert_integrity(
    *,
    state: dict,
    current_ids: set[str],
) -> None:

    queue = [
        str(x)
        for x in state[
            "queue"
        ]
    ]

    leases = [
        str(x)
        for x in state[
            "leases"
        ]
    ]


    combined = (
        queue
        + leases
    )


    if len(combined) != len(
        set(combined)
    ):

        raise RuntimeError(
            "queue duplicates detected"
        )


    # Orphan leases are legal ONLY while workers
    # are currently active. Final integrity audit
    # requires no leases.
    if leases:

        represented = (
            set(queue)
            | (
                set(leases)
                & current_ids
            )
        )

        if represented != current_ids:

            raise RuntimeError(
                "active queue membership mismatch"
            )

    else:

        if set(queue) != current_ids:

            raise RuntimeError(
                "queue membership mismatch"
            )
