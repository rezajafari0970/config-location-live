#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

MOD="$R/app/panel/read_model.py"

TS=$(date -u +%Y%m%d-%H%M%S)
BACKUP="$R/backups/PANEL-A2-$TS"

mkdir -p "$BACKUP"

if [ -f "$MOD" ]; then
    cp -a "$MOD" "$BACKUP/read_model.py.before"
fi

echo "BACKUP=$BACKUP"


echo
echo "=== 1. CREATE READ-ONLY PANEL MODEL ==="

cat >"$MOD" <<'PY'
from __future__ import annotations

from collections import Counter
from pathlib import Path
from typing import Any
import json


STATE_ROOT = Path(
    "/var/lib/config-location"
)

CONFIG_ROOT = (
    STATE_ROOT / "configs"
)

HEALTH_ROOT = (
    STATE_ROOT
    / "health-results"
    / "latest"
)

LIFECYCLE_ROOT = (
    STATE_ROOT
    / "health-lifecycle"
)

COUNTRY_ROOT = (
    STATE_ROOT
    / "country"
)

IDENTITY_ROOT = (
    COUNTRY_ROOT
    / "country-identity"
)

PIPELINE_ROOT = (
    COUNTRY_ROOT
    / "pipeline"
    / "latest"
)


UNCERTAIN_STATES = {
    "ambiguous",
    "unknown",
    "unresolved",
}


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


def _first_existing(
    root: Path,
    config_id: str,
) -> dict[str, Any] | None:

    path=(
        root
        /f"{config_id}.json"
    )

    if not path.exists():
        return None

    return _read_json(path)


def _config_id_from_record(
    record: dict[str, Any],
    fallback: str,
) -> str:

    return str(
        record.get("config_id")
        or record.get("id")
        or fallback
    )


def iter_config_records():

    if not CONFIG_ROOT.exists():
        return

    for path in sorted(
        CONFIG_ROOT.glob("*.json")
    ):

        record=_read_json(path)

        if record is None:
            continue

        cid=_config_id_from_record(
            record,
            path.stem,
        )

        yield (
            cid,
            record,
        )


def _country_view(
    *,
    identity: dict[str, Any] | None,
    pipeline: dict[str, Any] | None,
) -> dict[str, Any]:

    identity=identity or {}
    pipeline=pipeline or {}

    locked=(
        identity.get("locked")
        is True
        and bool(
            identity.get(
                "country_code"
            )
        )
    )

    if locked:

        code=str(
            identity.get(
                "country_code"
            )
        ).upper()

        name=(
            identity.get(
                "country_name"
            )
            or pipeline.get(
                "country_name"
            )
        )

        source="identity"

    else:

        code=(
            str(
                pipeline.get(
                    "country_code"
                )
            ).upper()
            if pipeline.get(
                "country_code"
            )
            else None
        )

        name=pipeline.get(
            "country_name"
        )

        source=(
            "pipeline"
            if code
            else None
        )


    state=str(
        pipeline.get(
            "state"
        )
        or "unknown"
    )


    unresolved=(
        not bool(code)
        or state.lower()
        in UNCERTAIN_STATES
    )


    return {
        "country_code":
            code,

        "country_name":
            name,

        "country_locked":
            locked,

        "country_source":
            source,

        "country_state":
            state,

        "country_unresolved":
            unresolved,

        "exit_ip":
            pipeline.get(
                "exit_ip"
            ),

        "country_confidence":
            pipeline.get(
                "confidence"
            ),

        "rotating":
            state.lower()
            =="confirmed_rotating",
    }


def build_config_view(
    config_id: str,
    config: dict[str, Any],
) -> dict[str, Any]:

    health=_first_existing(
        HEALTH_ROOT,
        config_id,
    )

    lifecycle=_first_existing(
        LIFECYCLE_ROOT,
        config_id,
    )

    identity=_first_existing(
        IDENTITY_ROOT,
        config_id,
    )

    pipeline=_first_existing(
        PIPELINE_ROOT,
        config_id,
    )


    country=_country_view(
        identity=identity,
        pipeline=pipeline,
    )


    source_ids=(
        config.get("source_ids")
        or []
    )

    if not isinstance(
        source_ids,
        list,
    ):
        source_ids=[]


    health_status=(
        (health or {}).get(
            "status"
        )
        or (health or {}).get(
            "health_status"
        )
        or "unknown"
    )


    lifecycle_state=(
        (lifecycle or {}).get(
            "state"
        )
        or (lifecycle or {}).get(
            "status"
        )
        or "unknown"
    )


    return {
        "config_id":
            config_id,

        "config_type":
            config.get(
                "config_type"
            )
            or config.get(
                "type"
            )
            or "unknown",

        "last_seen":
            config.get(
                "last_seen"
            ),

        "first_seen":
            config.get(
                "first_seen"
            ),

        "source_count":
            len(source_ids),

        "source_ids":
            source_ids,

        "health_status":
            str(
                health_status
            ),

        "lifecycle_state":
            str(
                lifecycle_state
            ),

        **country,
    }


def iter_config_views():

    for cid,config in (
        iter_config_records()
    ):

        yield build_config_view(
            cid,
            config,
        )


def dashboard_summary() -> dict[str, Any]:

    total=0

    types=Counter()
    health=Counter()
    lifecycle=Counter()
    countries=Counter()
    country_states=Counter()

    country_known=0
    unresolved=0
    rotating=0

    for row in iter_config_views():

        total+=1

        types[
            row["config_type"]
        ]+=1

        health[
            row["health_status"]
        ]+=1

        lifecycle[
            row["lifecycle_state"]
        ]+=1

        country_states[
            row["country_state"]
        ]+=1


        if row[
            "country_code"
        ]:

            country_known+=1

            countries[
                row["country_code"]
            ]+=1


        if row[
            "country_unresolved"
        ]:
            unresolved+=1


        if row[
            "rotating"
        ]:
            rotating+=1


    return {
        "total_configs":
            total,

        "country_known":
            country_known,

        "country_unresolved":
            unresolved,

        "country_rotating":
            rotating,

        "country_coverage_percent":
            round(
                (
                    country_known
                    /total
                    *100.0
                )
                if total
                else 0.0,
                2,
            ),

        "types":
            dict(types),

        "health":
            dict(health),

        "lifecycle":
            dict(lifecycle),

        "country_states":
            dict(
                country_states
            ),

        "countries":
            dict(
                countries.most_common()
            ),
    }


def query_configs(
    *,
    search: str = "",
    config_type: str = "",
    health_status: str = "",
    country_code: str = "",
    country_state: str = "",
    unresolved_only: bool = False,
    offset: int = 0,
    limit: int = 100,
) -> dict[str, Any]:

    search=search.strip().lower()

    config_type=(
        config_type
        .strip()
        .lower()
    )

    health_status=(
        health_status
        .strip()
        .lower()
    )

    country_code=(
        country_code
        .strip()
        .upper()
    )

    country_state=(
        country_state
        .strip()
        .lower()
    )


    offset=max(
        0,
        int(offset),
    )

    limit=max(
        1,
        min(
            int(limit),
            500,
        ),
    )


    matched=[]


    for row in iter_config_views():

        if (
            config_type
            and str(
                row[
                    "config_type"
                ]
            ).lower()
            !=config_type
        ):
            continue


        if (
            health_status
            and str(
                row[
                    "health_status"
                ]
            ).lower()
            !=health_status
        ):
            continue


        if (
            country_code
            and str(
                row[
                    "country_code"
                ]
                or ""
            ).upper()
            !=country_code
        ):
            continue


        if (
            country_state
            and str(
                row[
                    "country_state"
                ]
            ).lower()
            !=country_state
        ):
            continue


        if (
            unresolved_only
            and not row[
                "country_unresolved"
            ]
        ):
            continue


        if search:

            haystack=" ".join(
                [
                    str(
                        row.get(
                            "config_id",
                            "",
                        )
                    ),

                    str(
                        row.get(
                            "config_type",
                            "",
                        )
                    ),

                    str(
                        row.get(
                            "country_code",
                            "",
                        )
                    ),

                    str(
                        row.get(
                            "country_name",
                            "",
                        )
                    ),

                    str(
                        row.get(
                            "exit_ip",
                            "",
                        )
                    ),
                ]
            ).lower()

            if search not in haystack:
                continue


        matched.append(row)


    total=len(matched)

    page=matched[
        offset:
        offset+limit
    ]


    return {
        "total":
            total,

        "offset":
            offset,

        "limit":
            limit,

        "items":
            page,
    }
PY


"$PY" -m py_compile "$MOD"

echo "READ_MODEL_COMPILE=PASS"


echo
echo "=== 2. READ-ONLY SAFETY CHECK ==="

if grep -nE \
'write_text|unlink|remove|rmtree|rename|replace|mkdir|open\(.*["'\'']w|systemctl|subprocess' \
"$MOD"
then
    echo "ERROR=WRITE_OPERATION_FOUND"
    exit 1
fi

echo "READ_ONLY_CONTRACT=PASS"


echo
echo "=== 3. LIVE SUMMARY TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.read_model import (
    dashboard_summary,
)

s=dashboard_summary()

print(
    "TOTAL_CONFIGS=",
    s["total_configs"],
)

print(
    "COUNTRY_KNOWN=",
    s["country_known"],
)

print(
    "COUNTRY_UNRESOLVED=",
    s["country_unresolved"],
)

print(
    "COUNTRY_ROTATING=",
    s["country_rotating"],
)

print(
    "COUNTRY_COVERAGE_PERCENT=",
    s[
        "country_coverage_percent"
    ],
)

print(
    "HEALTH=",
    s["health"],
)

print(
    "COUNTRY_STATES=",
    s["country_states"],
)

assert (
    s["total_configs"]
    >0
)

print(
    "SUMMARY_TEST=PASS"
)
PY


echo
echo "=== 4. QUERY / PAGINATION TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.panel.read_model import (
    query_configs,
)

r=query_configs(
    limit=25,
)

print(
    "TOTAL=",
    r["total"],
)

print(
    "RETURNED=",
    len(
        r["items"]
    ),
)

assert r["total"]>0
assert len(r["items"])<=25


u=query_configs(
    unresolved_only=True,
    limit=25,
)

print(
    "UNRESOLVED_TOTAL=",
    u["total"],
)

for row in u["items"]:

    assert row[
        "country_unresolved"
    ] is True


print(
    "QUERY_TEST=PASS"
)
PY


echo
echo "=== 5. COUNTRY IDENTITY AUTHORITY TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.panel.read_model import (
    build_config_view,
)

I=Path(
    "/var/lib/config-location/"
    "country/country-identity"
)

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

tested=0

for ip in I.glob("*.json"):

    try:
        ident=json.loads(
            ip.read_text()
        )
    except Exception:
        continue

    if not (
        ident.get("locked") is True
        and ident.get("country_code")
    ):
        continue

    cid=str(
        ident.get("config_id")
        or ip.stem
    )

    row=build_config_view(
        cid,
        {
            "config_id":cid,
            "config_type":
                "test",
            "source_ids":[],
        },
    )

    assert (
        str(
            row[
                "country_code"
            ]
        ).upper()
        ==
        str(
            ident[
                "country_code"
            ]
        ).upper()
    )

    assert (
        row[
            "country_source"
        ]
        =="identity"
    )

    tested+=1

    if tested>=100:
        break


print(
    "IDENTITY_AUTHORITY_TESTED=",
    tested,
)

assert tested>0

print(
    "IDENTITY_AUTHORITY=PASS"
)
PY


echo
echo "=== 6. PRODUCTION SERVICES ==="

for S in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-country-event-consumer.service
do

    X=$(
        systemctl is-active \
        "$S" 2>/dev/null || true
    )

    echo "$S=$X"

    test "$X" = active
done


echo
echo "======================================================"
echo "PANEL_A2=PASS"
echo "COUNTRY_READ_MODEL=READY"
echo "PRODUCTION_MUTATION=NO"
echo "PANEL_RESTART=NO"
echo "NEXT=PANEL-A3-COUNTRY-API"
echo "======================================================"
