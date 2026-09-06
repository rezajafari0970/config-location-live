from __future__ import annotations

import fcntl
import json
import os
import time

from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from .batch import (
    BatchJob,
    BatchRunner,
    BatchSummary,
)

from ..storage.json_store import (
    JsonHealthResultStore,
)


class SchedulerBusy(RuntimeError):
    pass


@dataclass(frozen=True)
class SchedulerConfig:
    max_workers: int = 2
    batch_size: int = 20
    lock_path: Path = Path(
        "/run/config-location-health.lock"
    )
    cursor_path: Path = Path(
        "/var/lib/config-location/"
        "health-scheduler/cursor.json"
    )


@dataclass(frozen=True)
class SchedulerRun:
    selected: int
    completed: int
    healthy: int
    unhealthy: int
    error: int
    next_cursor: int
    duration_ms: int


class SchedulerLock:
    def __init__(
        self,
        path: Path,
    ) -> None:
        self.path = path
        self.fd: int | None = None

    def acquire(self) -> None:
        self.path.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        fd = os.open(
            self.path,
            os.O_CREAT | os.O_RDWR,
            0o600,
        )

        try:
            fcntl.flock(
                fd,
                fcntl.LOCK_EX
                | fcntl.LOCK_NB,
            )
        except BlockingIOError:
            os.close(fd)
            raise SchedulerBusy(
                "health scheduler already running"
            )

        self.fd = fd

        os.ftruncate(fd, 0)

        os.write(
            fd,
            str(os.getpid()).encode(),
        )

    def release(self) -> None:
        if self.fd is None:
            return

        try:
            fcntl.flock(
                self.fd,
                fcntl.LOCK_UN,
            )
        finally:
            os.close(self.fd)
            self.fd = None

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(
        self,
        exc_type,
        exc,
        tb,
    ):
        self.release()
        return False


def load_cursor(
    path: Path,
) -> int:
    if not path.exists():
        return 0

    try:
        obj = json.loads(
            path.read_text(
                encoding="utf-8"
            )
        )

        value = int(
            obj.get(
                "cursor",
                0,
            )
        )

        return max(
            0,
            value,
        )

    except Exception:
        return 0


def save_cursor(
    path: Path,
    cursor: int,
) -> None:
    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    tmp = (
        path.parent
        / (
            "."
            + path.name
            + ".tmp"
        )
    )

    tmp.write_text(
        json.dumps(
            {
                "cursor": int(cursor),
            },
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )

    tmp.chmod(0o600)

    os.replace(
        tmp,
        path,
    )


def select_batch(
    jobs: Iterable[BatchJob],
    *,
    cursor: int,
    batch_size: int,
) -> tuple[
    list[BatchJob],
    int,
]:

    items = list(jobs)

    if not items:
        return [], 0

    if batch_size < 1:
        raise ValueError(
            "batch_size must be >= 1"
        )

    cursor = cursor % len(items)

    selected = []

    index = cursor

    limit = min(
        batch_size,
        len(items),
    )

    for _ in range(limit):
        selected.append(
            items[index]
        )

        index = (
            index + 1
        ) % len(items)

    return (
        selected,
        index,
    )


class HealthScheduler:

    def __init__(
        self,
        *,
        config: SchedulerConfig,
        result_store: JsonHealthResultStore,
    ) -> None:
        self.config = config
        self.result_store = result_store

    def run_once(
        self,
        jobs: Iterable[BatchJob],
    ) -> SchedulerRun:

        started = time.monotonic()

        with SchedulerLock(
            self.config.lock_path
        ):
            cursor = load_cursor(
                self.config.cursor_path
            )

            selected, next_cursor = (
                select_batch(
                    jobs,
                    cursor=cursor,
                    batch_size=(
                        self.config.batch_size
                    ),
                )
            )

            runner = BatchRunner(
                max_workers=(
                    self.config.max_workers
                ),
                result_store=(
                    self.result_store
                ),
            )

            _, summary = runner.run(
                selected
            )

            save_cursor(
                self.config.cursor_path,
                next_cursor,
            )

        duration_ms = int(
            (
                time.monotonic()
                - started
            )
            * 1000
        )

        return SchedulerRun(
            selected=len(selected),
            completed=summary.completed,
            healthy=summary.healthy,
            unhealthy=summary.unhealthy,
            error=summary.error,
            next_cursor=next_cursor,
            duration_ms=duration_ms,
        )


def mix_jobs_by_type(
    jobs: Iterable[BatchJob],
    *,
    type_order: tuple[str, ...] = (
        "vless",
        "vmess",
        "ss",
        "trojan",
        "json_xray",
    ),
) -> list[BatchJob]:
    """
    Build one deterministic fair sequence.

    Jobs from different config types are interleaved
    round-robin. When a small type is exhausted, the
    remaining types continue normally.

    Important:
    - every input job appears exactly once
    - no duplicate config IDs are created
    - deterministic ordering
    - existing global cursor remains valid
    - a full cursor cycle still visits every config
    """

    items = list(jobs)

    buckets: dict[
        str,
        list[BatchJob],
    ] = {}

    for job in items:
        buckets.setdefault(
            job.config_type,
            [],
        ).append(job)

    for bucket in buckets.values():
        bucket.sort(
            key=lambda job: (
                job.config_id
            )
        )

    ordered_types = [
        kind
        for kind in type_order
        if kind in buckets
    ]

    ordered_types.extend(
        sorted(
            kind
            for kind in buckets
            if kind not in type_order
        )
    )

    indexes = {
        kind: 0
        for kind in ordered_types
    }

    result: list[
        BatchJob
    ] = []

    while True:

        added = False

        for kind in ordered_types:

            bucket = buckets[kind]
            index = indexes[kind]

            if index >= len(bucket):
                continue

            result.append(
                bucket[index]
            )

            indexes[kind] = (
                index + 1
            )

            added = True

        if not added:
            break

    if len(result) != len(items):
        raise RuntimeError(
            "fair-mix size mismatch"
        )

    return result
