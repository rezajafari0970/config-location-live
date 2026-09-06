from __future__ import annotations

import json

from collections import Counter
from pathlib import Path
from typing import Any

from app.country.projection import (
    build_projection,
)

from app.publish.filter import (
    publishable_config_ids,
)


CONFIG_ROOT = Path(
    "/var/lib/config-location/configs"
)


UNKNOWN_VALUES = {
    "",
    "unknown",
    "UNKNOWN",
    "Unknown",
    "ناشناس",
    "none",
    "None",
    "null",
    "--",
}


def read_json(
    path: Path,
) -> Any:

    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        return None


def clean(
    value: Any,
) -> str | None:

    if value is None:
        return None

    value=str(value).strip()

    if value in UNKNOWN_VALUES:
        return None

    return value or None


def current_configs() -> dict[str,dict[str,Any]]:

    rows={}

    for path in CONFIG_ROOT.glob(
        "*.json"
    ):

        obj=read_json(path)

        if not isinstance(obj,dict):
            continue

        cid=str(
            obj.get(
                "config_id",
                path.stem,
            )
        )

        rows[cid]=obj

    return rows


def config_store_country(
    obj: dict[str,Any],
) -> dict[str,Any]:

    code=clean(
        obj.get(
            "country_code"
        )
    )

    name=clean(
        obj.get(
            "country_name"
        )
    )

    country=clean(
        obj.get("country")
    )

    if country:

        if (
            not code
            and len(country)==2
            and country.isalpha()
        ):
            code=country.upper()

        elif not name:
            name=country


    return {
        "country_code":
            code,

        "country_name":
            name,

        "known":
            bool(code or name),
    }


def build_panel_shadow() -> dict[str,Any]:

    configs=current_configs()
    projection=build_projection()

    records={}

    counters=Counter()

    for cid,obj in configs.items():

        projected=projection[
            "records"
        ].get(
            cid,
            {}
        )

        existing=config_store_country(
            obj
        )

        state=projected.get(
            "state",
            "unknown",
        )

        if state=="resolved":
            counters["resolved"] += 1

        elif state=="conflict":
            counters["conflict"] += 1

        else:
            counters["unknown"] += 1


        if existing["known"]:
            counters[
                "config_store_known"
            ] += 1


        if (
            not existing["known"]
            and state=="resolved"
        ):
            counters[
                "projection_recovers_missing"
            ] += 1


        records[cid]={
            "config_id":
                cid,

            "existing": {
                "country_code":
                    existing[
                        "country_code"
                    ],

                "country_name":
                    existing[
                        "country_name"
                    ],
            },

            "shadow": {
                "state":
                    state,

                "country_code":
                    projected.get(
                        "country_code"
                    ),

                "country_name":
                    projected.get(
                        "country_name"
                    ),

                "flag":
                    projected.get(
                        "flag"
                    ),

                "confidence":
                    projected.get(
                        "confidence"
                    ),

                "source":
                    projected.get(
                        "selected_source"
                    ),

                "path":
                    projected.get(
                        "selected_path"
                    ),
            },

            "production_panel_mutated":
                False,
        }


    return {
        "mode":
            "panel_shadow",

        "production_wiring":
            False,

        "current_config_count":
            len(configs),

        "counts":
            dict(counters),

        "records":
            records,
    }


def publish_group_key(
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


    code=clean(
        row.get(
            "country_code"
        )
    )

    if code:
        return code.upper()


    name=clean(
        row.get(
            "country_name"
        )
    )

    if name:
        return (
            "NAME:"
            + name
        )


    return "UNKNOWN"


def build_publish_shadow() -> dict[str,Any]:

    projection=build_projection()

    current=set(
        projection[
            "records"
        ]
    )

    publishable={
        str(cid)
        for cid in
        publishable_config_ids()
    }

    publishable &= current


    groups=Counter()

    resolved=0
    unknown=0
    conflict=0

    sample_by_group={}


    for cid in sorted(
        publishable
    ):

        row=projection[
            "records"
        ][cid]

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


        key=publish_group_key(
            row
        )

        groups[key] += 1


        bucket=sample_by_group.setdefault(
            key,
            []
        )

        if len(bucket) < 10:

            bucket.append(
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

                    "source":
                        row.get(
                            "selected_source"
                        ),
                }
            )


    return {
        "mode":
            "publish_shadow",

        "production_wiring":
            False,

        "publishable_count":
            len(publishable),

        "resolved":
            resolved,

        "unknown":
            unknown,

        "conflict":
            conflict,

        "group_counts":
            dict(
                groups.most_common()
            ),

        "group_samples":
            sample_by_group,
    }


def build_summary() -> dict[str,Any]:

    panel=build_panel_shadow()
    publish=build_publish_shadow()


    panel_total=int(
        panel[
            "current_config_count"
        ]
    )

    panel_resolved=int(
        panel[
            "counts"
        ].get(
            "resolved",
            0,
        )
    )


    publish_total=int(
        publish[
            "publishable_count"
        ]
    )

    publish_resolved=int(
        publish[
            "resolved"
        ]
    )


    return {
        "phase":
            "phase5-pass5-panel-publish-shadow-integration",

        "mode":
            "shadow_only",

        "panel": {
            "current_config_count":
                panel_total,

            "resolved":
                panel_resolved,

            "unknown":
                panel[
                    "counts"
                ].get(
                    "unknown",
                    0,
                ),

            "conflict":
                panel[
                    "counts"
                ].get(
                    "conflict",
                    0,
                ),

            "config_store_known":
                panel[
                    "counts"
                ].get(
                    "config_store_known",
                    0,
                ),

            "projection_recovers_missing":
                panel[
                    "counts"
                ].get(
                    "projection_recovers_missing",
                    0,
                ),

            "resolved_percent":
                round(
                    (
                        panel_resolved
                        * 100
                        / panel_total
                    )
                    if panel_total
                    else 0,
                    3,
                ),
        },

        "publish": {
            "publishable_count":
                publish_total,

            "resolved":
                publish_resolved,

            "unknown":
                publish[
                    "unknown"
                ],

            "conflict":
                publish[
                    "conflict"
                ],

            "resolved_percent":
                round(
                    (
                        publish_resolved
                        * 100
                        / publish_total
                    )
                    if publish_total
                    else 0,
                    3,
                ),

            "country_group_count":
                len(
                    publish[
                        "group_counts"
                    ]
                ),
        },

        "production": {
            "panel_wiring":
                False,

            "publish_wiring":
                False,

            "endpoint_mutation":
                False,

            "config_mutation":
                False,

            "country_store_mutation":
                False,
        },
    }
