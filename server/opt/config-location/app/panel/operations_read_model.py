from __future__ import annotations

from pathlib import Path
from typing import Any
import json
import time


# ============================================================
# PANEL_A6_OPERATIONS_READ_MODEL
# READ ONLY
# ============================================================

XRAY_FAILURE_ROOTS = (
    Path(
        "/var/log/config-location/"
        "xray/failures"
    ),
    Path(
        "/var/log/config-location/"
        "xray-full-audit"
    ),
)


def _read_json(
    path: Path,
) -> dict[str, Any] | None:

    try:

        value=json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )

    except (
        OSError,
        ValueError,
        TypeError,
    ):
        return None

    if not isinstance(
        value,
        dict,
    ):
        return None

    return value


def _event_bus_stats() -> dict[str, Any]:

    try:

        from app.country.event_bus import (
            stats,
        )

        value=stats()

    except Exception as exc:

        return {
            "available":False,
            "error":
                type(exc).__name__,
            "message":
                str(exc),
        }


    if not isinstance(
        value,
        dict,
    ):

        return {
            "available":False,
            "error":
                "invalid_stats_type",
        }


    result={
        "available":True,
    }

    result.update(value)

    return result


def _bundle_json_candidates(
    root: Path,
):

    preferred=[
        "failure.json",
        "metadata.json",
        "manifest.json",
        "runtime.json",
        "report.json",
    ]

    seen=set()

    for name in preferred:

        path=root/name

        if path.is_file():

            seen.add(path)

            yield path


    for path in sorted(
        root.glob("*.json")
    ):

        if path in seen:
            continue

        yield path


def _bundle_metadata(
    bundle: Path,
) -> dict[str, Any]:

    merged={}

    json_files=[]

    for path in _bundle_json_candidates(
        bundle
    ):

        json_files.append(
            path.name
        )

        value=_read_json(path)

        if value is None:
            continue


        # Preserve first meaningful value.
        for key in (
            "config_id",
            "stage",
            "exception",
            "exception_type",
            "message",
            "error",
            "status",
            "created_at",
            "timestamp",
            "config_type",
        ):

            if (
                key not in merged
                and value.get(key)
                not in (
                    None,
                    "",
                )
            ):
                merged[key]=value.get(
                    key
                )


    files=[]

    try:

        for path in sorted(
            bundle.iterdir()
        ):

            if not path.is_file():
                continue

            try:
                size=path.stat().st_size
            except OSError:
                size=None

            files.append(
                {
                    "name":path.name,
                    "size":size,
                }
            )

    except OSError:
        pass


    try:

        stat=bundle.stat()

        mtime=stat.st_mtime

    except OSError:

        mtime=0.0


    stage=(
        merged.get("stage")
        or merged.get("status")
        or "unknown"
    )

    exception=(
        merged.get("exception")
        or merged.get(
            "exception_type"
        )
        or merged.get("error")
    )


    return {
        "bundle_id":
            bundle.name,

        "path":
            str(bundle),

        "mtime_epoch":
            mtime,

        "mtime_iso":
            time.strftime(
                "%Y-%m-%dT%H:%M:%SZ",
                time.gmtime(mtime),
            )
            if mtime
            else None,

        "config_id":
            merged.get(
                "config_id"
            ),

        "config_type":
            merged.get(
                "config_type"
            ),

        "stage":
            stage,

        "exception":
            exception,

        "message":
            merged.get(
                "message"
            ),

        "created_at":
            merged.get(
                "created_at"
            )
            or merged.get(
                "timestamp"
            ),

        "json_files":
            json_files,

        "files":
            files,
    }


def iter_xray_failure_bundles():

    seen=set()

    for root in XRAY_FAILURE_ROOTS:

        if not root.is_dir():
            continue


        # Direct failure bundle directories.
        try:

            dirs=[
                p
                for p in root.iterdir()
                if p.is_dir()
            ]

        except OSError:

            continue


        # xray-full-audit may contain a jobs/
        # hierarchy; descend a small bounded depth.
        if (
            root.name
            =="xray-full-audit"
        ):

            nested=[]

            for path in root.glob(
                "*/jobs/*"
            ):

                if path.is_dir():
                    nested.append(path)

            dirs.extend(nested)


        for bundle in dirs:

            key=str(bundle)

            if key in seen:
                continue

            seen.add(key)

            yield _bundle_metadata(
                bundle
            )


def xray_failure_summary(
    *,
    limit: int = 100,
) -> dict[str, Any]:

    limit=max(
        1,
        min(
            int(limit),
            500,
        ),
    )

    rows=list(
        iter_xray_failure_bundles()
    )

    rows.sort(
        key=lambda x:
            float(
                x.get(
                    "mtime_epoch"
                )
                or 0
            ),
        reverse=True,
    )


    stages={}
    exceptions={}

    for row in rows:

        stage=str(
            row.get("stage")
            or "unknown"
        )

        stages[stage]=(
            stages.get(stage,0)
            +1
        )


        exc=str(
            row.get("exception")
            or "unknown"
        )

        exceptions[exc]=(
            exceptions.get(exc,0)
            +1
        )


    return {
        "total":
            len(rows),

        "stages":
            stages,

        "exceptions":
            exceptions,

        "items":
            rows[:limit],
    }


def operations_summary() -> dict[str, Any]:

    return {
        "event_bus":
            _event_bus_stats(),

        "xray_failures":
            xray_failure_summary(
                limit=50,
            ),
    }


def xray_failure_detail(
    bundle_id: str,
) -> dict[str, Any] | None:

    bundle_id=str(
        bundle_id
        or ""
    ).strip()


    if not bundle_id:

        return None


    # Reject path traversal.
    if (
        "/" in bundle_id
        or "\\" in bundle_id
        or bundle_id
        in {
            ".",
            "..",
        }
    ):
        return None


    for row in iter_xray_failure_bundles():

        if (
            row.get(
                "bundle_id"
            )
            !=bundle_id
        ):
            continue


        path=Path(
            row["path"]
        )


        content={}


        for name in (
            "failure.json",
            "metadata.json",
            "manifest.json",
            "runtime.json",
            "report.json",
            "xray-test.stderr.log",
            "xray-test.stdout.log",
            "xray-runtime.stderr.log",
            "xray-runtime.stdout.log",
        ):

            file_path=path/name

            if not file_path.is_file():
                continue


            try:

                text=file_path.read_text(
                    encoding="utf-8",
                    errors="replace",
                )

            except OSError:

                continue


            # Safety cap for UI/API.
            content[name]=text[
                -20000:
            ]


        result=dict(row)

        result[
            "content"
        ]=content

        return result


    return None
