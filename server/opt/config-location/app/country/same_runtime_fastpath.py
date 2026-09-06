from __future__ import annotations

import json
import os
import time

from pathlib import Path
from typing import Any

from .exit_observer import observe_exit_ip


METRICS=Path(
    "/var/lib/config-location/country/"
    "same-runtime-fastpath.jsonl"
)


def _metric(row: dict[str,Any]) -> None:

    try:
        METRICS.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        line=(
            json.dumps(
                row,
                ensure_ascii=False,
                sort_keys=True,
            )
            + "\n"
        )

        fd=os.open(
            METRICS,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_APPEND,
            0o600,
        )

        try:
            os.write(
                fd,
                line.encode(),
            )
        finally:
            os.close(fd)

    except Exception:
        pass


def run_same_runtime_fastpath(
    *,
    config_id: str,
    job_id: str,
    proxy_url: str,
) -> dict[str,Any]:

    started=time.monotonic()

    try:

        obs=observe_exit_ip(
            proxy_url=proxy_url,
            timeout=3.0,
            minimum_agreement=2,
        )

        elapsed_ms=int(
            (
                time.monotonic()
                - started
            )
            * 1000
        )

        exit_ip=getattr(
            obs,
            "exit_ip",
            None,
        )

        agreed=getattr(
            obs,
            "agreed",
            None,
        )

        status=(
            "success"
            if exit_ip
            else "no_exit_ip"
        )

        row={
            "ts_ns":time.time_ns(),
            "config_id":config_id,
            "job_id":job_id,
            "status":status,
            "exit_ip":exit_ip,
            "agreed":agreed,
            "elapsed_ms":elapsed_ms,
            "same_runtime":True,
            "new_xray_started":False,
        }

        _metric(row)

        return row

    except Exception as exc:

        elapsed_ms=int(
            (
                time.monotonic()
                - started
            )
            * 1000
        )

        row={
            "ts_ns":time.time_ns(),
            "config_id":config_id,
            "job_id":job_id,
            "status":"error",
            "error":(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:500],
            "elapsed_ms":elapsed_ms,
            "same_runtime":True,
            "new_xray_started":False,
        }

        _metric(row)

        return row
