from __future__ import annotations

from concurrent.futures import (
    ThreadPoolExecutor,
    as_completed,
)
from dataclasses import dataclass
from typing import Any, Iterable

from .engine import run_health_once
from .models import (
    HealthResult,
    HealthState,
)

from ..storage.json_store import (
    JsonHealthResultStore,
)


@dataclass(frozen=True)
class BatchJob:
    config_id: str
    config_type: str
    source: Any


@dataclass(frozen=True)
class BatchSummary:
    total: int
    completed: int
    healthy: int
    unhealthy: int
    error: int
    max_workers: int


class BatchRunner:
    """
    Controlled-concurrency health runner.

    Every health job receives:
      - its own Xray process
      - its own loopback SOCKS port
      - its own sandbox
      - its own logs

    This class never uses shared runtime ports.
    """

    def __init__(
        self,
        *,
        max_workers: int = 2,
        result_store: (
            JsonHealthResultStore
            | None
        ) = None,
    ) -> None:

        if max_workers < 1:
            raise ValueError(
                "max_workers must be >= 1"
            )

        self.max_workers = max_workers
        self.result_store = result_store

    def _run_one(
        self,
        job: BatchJob,
    ) -> HealthResult:

        result = run_health_once(
            config_id=job.config_id,
            config_type=job.config_type,
            source=job.source,
        )

        if self.result_store is not None:
            self.result_store.save(
                result
            )

        return result

    def run(
        self,
        jobs: Iterable[BatchJob],
    ) -> tuple[
        list[HealthResult],
        BatchSummary,
    ]:

        items = list(jobs)

        if not items:
            return (
                [],
                BatchSummary(
                    total=0,
                    completed=0,
                    healthy=0,
                    unhealthy=0,
                    error=0,
                    max_workers=(
                        self.max_workers
                    ),
                ),
            )

        results: list[
            HealthResult
        ] = []

        with ThreadPoolExecutor(
            max_workers=self.max_workers,
            thread_name_prefix=(
                "config-health"
            ),
        ) as pool:

            future_map = {
                pool.submit(
                    self._run_one,
                    job,
                ): job

                for job in items
            }

            for future in as_completed(
                future_map
            ):
                job = future_map[
                    future
                ]

                try:
                    result = (
                        future.result()
                    )

                except Exception as exc:

                    result = HealthResult(
                        job_id=(
                            "batch-exception-"
                            + job.config_id
                        ),
                        config_id=(
                            job.config_id
                        ),
                        config_type=(
                            job.config_type
                        ),
                        state=(
                            HealthState.ERROR
                        ),
                        error_code=(
                            type(
                                exc
                            ).__name__
                        ),
                        error_message=str(
                            exc
                        ),
                    )

                    if (
                        self.result_store
                        is not None
                    ):
                        self.result_store.save(
                            result
                        )

                results.append(
                    result
                )

        healthy = sum(
            1
            for r in results
            if (
                r.state
                == HealthState.HEALTHY
            )
        )

        unhealthy = sum(
            1
            for r in results
            if (
                r.state
                == HealthState.UNHEALTHY
            )
        )

        error = sum(
            1
            for r in results
            if (
                r.state
                == HealthState.ERROR
            )
        )

        summary = BatchSummary(
            total=len(items),
            completed=len(results),
            healthy=healthy,
            unhealthy=unhealthy,
            error=error,
            max_workers=(
                self.max_workers
            ),
        )

        return (
            results,
            summary,
        )
