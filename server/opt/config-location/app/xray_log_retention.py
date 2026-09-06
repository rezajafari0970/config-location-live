from __future__ import annotations

from pathlib import Path
from typing import Any
import hashlib
import json
import os
import shutil
import time


BASE = Path(
    "/var/log/config-location/xray"
)

RUNS = BASE / "runs"
FAILURES = BASE / "failures"
CONFIGS = BASE / "configs"

for p in (
    BASE,
    RUNS,
    FAILURES,
    CONFIGS,
):
    p.mkdir(
        parents=True,
        exist_ok=True,
    )


def _safe(value: Any) -> str:
    s=str(
        value
        if value is not None
        else "unknown"
    )

    allowed=[]

    for c in s:
        if (
            c.isalnum()
            or c in "-_."
        ):
            allowed.append(c)
        else:
            allowed.append("_")

    return "".join(
        allowed
    )[:180]


def archive_xray_run(
    *,
    config_id: str | None,
    stdout: str | bytes | None,
    stderr: str | bytes | None,
    returncode: int | None,
    runtime_path: str | os.PathLike | None = None,
    source_raw: str | bytes | None = None,
    stage: str | None = None,
    metadata: dict | None = None,
) -> dict:

    now=time.time_ns()

    cid=_safe(
        config_id
        or "unknown"
    )

    stage_s=_safe(
        stage
        or "xray"
    )

    stamp=time.strftime(
        "%Y%m%d-%H%M%S",
        time.gmtime(),
    )

    unique=(
        f"{stamp}-"
        f"{now % 1000000000:09d}-"
        f"{cid[:40]}"
    )

    failed=(
        returncode is None
        or int(returncode)!=0
    )

    root=(
        FAILURES
        if failed
        else RUNS
    ) / unique

    root.mkdir(
        parents=True,
        exist_ok=False,
    )


    def to_text(v):
        if v is None:
            return ""

        if isinstance(v,bytes):
            return v.decode(
                "utf-8",
                errors="replace",
            )

        return str(v)


    stdout_text=to_text(stdout)
    stderr_text=to_text(stderr)


    (root/"stdout.log").write_text(
        stdout_text,
        errors="replace",
    )

    (root/"stderr.log").write_text(
        stderr_text,
        errors="replace",
    )


    runtime_copy=None

    if runtime_path:

        rp=Path(runtime_path)

        if rp.exists() and rp.is_file():

            runtime_copy=(
                root/"runtime.json"
            )

            shutil.copy2(
                rp,
                runtime_copy,
            )


    source_sha256=None

    if source_raw is not None:

        raw=(
            source_raw
            if isinstance(
                source_raw,
                bytes,
            )
            else str(
                source_raw
            ).encode(
                "utf-8",
                errors="replace",
            )
        )

        source_sha256=hashlib.sha256(
            raw
        ).hexdigest()

        # Keep exact source.raw for forensic/debug use.
        (root/"source.raw").write_bytes(
            raw
        )


    manifest={
        "schema_version":1,
        "timestamp_ns":now,
        "timestamp_utc":time.strftime(
            "%Y-%m-%dT%H:%M:%SZ",
            time.gmtime(),
        ),
        "config_id":config_id,
        "stage":stage,
        "returncode":returncode,
        "failed":failed,
        "runtime_saved":
            runtime_copy is not None,
        "source_sha256":
            source_sha256,
        "stdout_bytes":
            len(
                stdout_text.encode(
                    "utf-8",
                    errors="replace",
                )
            ),
        "stderr_bytes":
            len(
                stderr_text.encode(
                    "utf-8",
                    errors="replace",
                )
            ),
        "metadata":
            metadata or {},
    }

    (root/"manifest.json").write_text(
        json.dumps(
            manifest,
            indent=2,
            sort_keys=True,
            ensure_ascii=False,
        )
    )

    return {
        "path":str(root),
        **manifest,
    }
