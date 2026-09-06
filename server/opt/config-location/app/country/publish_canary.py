from __future__ import annotations

import hashlib
import json
import os
import tempfile

from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.country.projection import (
    build_projection,
)

from app.publish.filter import (
    publishable_config_ids,
)


STATE_ROOT=Path(
    "/var/lib/config-location/country/publish-canary"
)

GROUP_ROOT=STATE_ROOT/"groups"

STATUS_PATH=STATE_ROOT/"status.json"

PRODUCTION_WIRING=False


def now_iso() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def atomic_json(
    path: Path,
    value: Any,
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd,tmp=tempfile.mkstemp(
        dir=str(path.parent),
        prefix="."+path.name+".",
        suffix=".tmp",
    )

    try:

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as fh:

            json.dump(
                value,
                fh,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())

        os.chmod(tmp,0o640)

        os.replace(
            tmp,
            path,
        )

    finally:

        if os.path.exists(tmp):
            os.unlink(tmp)


def sha256_json(
    value: Any,
) -> str:

    raw=json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",",":"),
    ).encode("utf-8")

    return hashlib.sha256(
        raw
    ).hexdigest()


def group_key(
    row: dict[str,Any],
) -> str:

    state=row.get(
        "state",
        "unknown",
    )

    if state=="conflict":
        return "CONFLICT"

    if state!="resolved":
        return "UNKNOWN"

    code=row.get(
        "country_code"
    )

    if isinstance(code,str):

        code=code.strip().upper()

        if (
            len(code)==2
            and code.isalpha()
        ):
            return code

    return "UNKNOWN"


def build_canary() -> dict[str,Any]:

    projection=build_projection()

    records=projection.get(
        "records",
        {},
    )

    current=set(records)

    publishable={
        str(cid)
        for cid in
        publishable_config_ids()
    }

    publishable &= current


    groups=defaultdict(list)

    resolved=0
    unknown=0
    conflict=0


    for cid in sorted(
        publishable
    ):

        row=records[cid]

        state=row.get(
            "state",
            "unknown",
        )

        if state=="resolved":
            resolved += 1

        elif state=="conflict":
            conflict += 1

        else:
            unknown += 1


        key=group_key(row)

        groups[key].append(
            {
                "config_id":
                    cid,

                "state":
                    state,

                "country_code":
                    row.get(
                        "country_code"
                    ),

                "country_name":
                    row.get(
                        "country_name"
                    ),

                "flag":
                    row.get(
                        "flag"
                    ),

                "confidence":
                    row.get(
                        "confidence"
                    ),

                "source":
                    row.get(
                        "selected_source"
                    ),

                "path":
                    row.get(
                        "selected_path"
                    ),
            }
        )


    group_meta={}

    for key,items in sorted(
        groups.items()
    ):

        group_meta[key]={
            "count":
                len(items),

            "sha256":
                sha256_json(items),
        }


    total=len(publishable)


    return {
        "component":
            "country-publish-canary",

        "schema":
            1,

        "mode":
            "canary_only",

        "production_wiring":
            False,

        "sub_all_mutated":
            False,

        "generated_at":
            now_iso(),

        "projection_schema":
            projection.get(
                "schema"
            ),

        "publishable_count":
            total,

        "resolved":
            resolved,

        "unknown":
            unknown,

        "conflict":
            conflict,

        "resolved_percent":
            round(
                (
                    resolved
                    * 100
                    / total
                )
                if total
                else 0,
                3,
            ),

        "group_count":
            len(groups),

        "group_meta":
            group_meta,

        "groups":
            dict(groups),
    }


def write_canary(
    data: dict[str,Any],
) -> None:

    GROUP_ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )


    # Only files inside the dedicated
    # canary namespace are replaced.
    expected=set()


    for key,items in data[
        "groups"
    ].items():

        path=(
            GROUP_ROOT
            / f"{key}.json"
        )

        expected.add(
            path.name
        )

        atomic_json(
            path,
            {
                "mode":
                    "canary_only",

                "production_wiring":
                    False,

                "group":
                    key,

                "count":
                    len(items),

                "sha256":
                    sha256_json(items),

                "records":
                    items,
            },
        )


    # Do not delete stale canary files yet.
    # Reconciliation is deliberately
    # non-destructive in Pass 6B.


    status={
        key:value
        for key,value in data.items()
        if key!="groups"
    }

    status[
        "expected_group_files"
    ]=sorted(expected)

    status[
        "stale_canary_cleanup"
    ]=False

    atomic_json(
        STATUS_PATH,
        status,
    )
