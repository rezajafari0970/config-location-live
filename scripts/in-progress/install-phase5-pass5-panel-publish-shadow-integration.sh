#!/usr/bin/env bash
set -Eeu

PHASE="phase5-pass5-panel-publish-shadow-integration"

PROJECT="/opt/config-location"
REPO="/root/project-log"

MODULE="$PROJECT/app/country/shadow_integration.py"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"
BACKUP_DIR="/root/3245/${PHASE}-backup-${TS}"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"

SUMMARY="$DISCOVERY_DIR/${PHASE}-${TS}-summary.json"
PANEL_SHADOW="$DISCOVERY_DIR/${PHASE}-${TS}-panel-shadow.json"
PUBLISH_SHADOW="$DISCOVERY_DIR/${PHASE}-${TS}-publish-shadow.json"

mkdir -p \
  "$RUN_DIR" \
  "$REPORT_DIR" \
  "$DISCOVERY_DIR" \
  "$BACKUP_DIR"

RESULT="SUCCESS"
ERRORS=""

exec 3> >(tee -a "$LOG")
exec 1>&3 2>&1

fail() {
    RESULT="FAILED"
    ERRORS="${ERRORS}\n$1"
    echo "ERROR: $1"
}

finish() {
    CODE=$?

    if [ "$CODE" -ne 0 ]; then
        RESULT="FAILED"
        ERRORS="${ERRORS}\nexit code $CODE"
    fi

    cat > "$REPORT" <<REPORT
CONFIG LOCATION REPORT

Phase:
$PHASE

Result:
$RESULT

Start:
$START

End:
$(date -Is)

Mode:
PANEL / PUBLISH SHADOW INTEGRATION

Production Panel wiring:
NO

Production Publish wiring:
NO

Config mutation:
NONE

Country-store mutation:
NONE

Endpoint mutation:
NONE

Service restart:
NONE

Summary:
$SUMMARY

Panel shadow:
$PANEL_SHADOW

Publish shadow:
$PUBLISH_SHADOW

Backup:
$BACKUP_DIR

Log:
$LOG

Errors:
$ERRORS
REPORT

    exec 1>&-
    exec 2>&-
    exec 3>&-

    sleep 1

    cd "$REPO" || exit 1

    git add \
      "$LOG" \
      "$REPORT" \
      "$SUMMARY" \
      "$PANEL_SHADOW" \
      "$PUBLISH_SHADOW" \
      >/dev/null 2>&1 || true

    if ! git diff --cached --quiet; then
        git commit \
          -m "Phase execution $PHASE $TS" \
          >/dev/null 2>&1 || true
    fi

    git push origin main >/dev/null 2>&1 || true

    [ "$RESULT" = "SUCCESS" ] || exit 1
}

trap finish EXIT


echo "================================================"
echo " PHASE 5 PASS 5"
echo " PANEL / PUBLISH SHADOW INTEGRATION"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/10] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

test -f "$PROJECT/app/country/projection.py" || {
    fail "projection.py missing"
    exit 1
}

test -f "$PROJECT/app/publish/filter.py" || {
    fail "publish filter missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/10] BACKUP =========="

if [ -f "$MODULE" ]; then
    cp -a \
      "$MODULE" \
      "$BACKUP_DIR/shadow_integration.py.before"
fi

echo "BACKUP_OK"


################################################
# 3 INSTALL SHADOW INTEGRATION
################################################

echo
echo "========== [3/10] INSTALL SHADOW MODULE =========="

cat > "$MODULE" <<'PY'
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
PY

echo "SHADOW_MODULE_INSTALLED"


################################################
# 4 COMPILE
################################################

echo
echo "========== [4/10] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/shadow_integration.py \
  app/country/projection.py \
  app/publish/filter.py

echo "COMPILE_OK"


################################################
# 5 SELFTEST
################################################

echo
echo "========== [5/10] SELFTEST =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.country.shadow_integration import (
    publish_group_key,
)

assert (
    publish_group_key(
        {
            "state":"resolved",
            "country_code":"DE",
        }
    )
    == "DE"
)

assert (
    publish_group_key(
        {
            "state":"unknown",
        }
    )
    == "UNKNOWN"
)

assert (
    publish_group_key(
        {
            "state":"conflict",
        }
    )
    == "CONFLICT"
)

print("SELFTEST_OK")
print("UNKNOWN_SEPARATED=YES")
print("CONFLICT_SEPARATED=YES")
PY


################################################
# 6 BUILD PANEL SHADOW
################################################

echo
echo "========== [6/10] PANEL SHADOW =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$PANEL_SHADOW" <<'PY'
import json
import sys

from app.country.shadow_integration import (
    build_panel_shadow,
)

data=build_panel_shadow()

with open(
    sys.argv[1],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        data,
        fh,
        ensure_ascii=False,
        indent=2,
    )

    fh.write("\n")


print(
    "PANEL_CONFIGS=",
    data[
        "current_config_count"
    ],
)

print(
    "PANEL_COUNTS=",
    data[
        "counts"
    ],
)
PY


################################################
# 7 BUILD PUBLISH SHADOW
################################################

echo
echo "========== [7/10] PUBLISH SHADOW =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$PUBLISH_SHADOW" <<'PY'
import json
import sys

from app.country.shadow_integration import (
    build_publish_shadow,
)

data=build_publish_shadow()

with open(
    sys.argv[1],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        data,
        fh,
        ensure_ascii=False,
        indent=2,
    )

    fh.write("\n")


print(
    "PUBLISHABLE=",
    data[
        "publishable_count"
    ],
)

print(
    "RESOLVED=",
    data[
        "resolved"
    ],
)

print(
    "UNKNOWN=",
    data[
        "unknown"
    ],
)

print(
    "CONFLICT=",
    data[
        "conflict"
    ],
)

print(
    "TOP_GROUPS="
)

for key,value in list(
    data[
        "group_counts"
    ].items()
)[:30]:

    print(
        key,
        value,
    )
PY


################################################
# 8 SUMMARY
################################################

echo
echo "========== [8/10] SUMMARY =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<'PY'
import json
import sys

from app.country.shadow_integration import (
    build_summary,
)

data=build_summary()

with open(
    sys.argv[1],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        data,
        fh,
        ensure_ascii=False,
        indent=2,
    )

    fh.write("\n")


print(
    json.dumps(
        data,
        ensure_ascii=False,
        indent=2,
    )
)
PY


################################################
# 9 VALIDATE
################################################

echo
echo "========== [9/10] VALIDATE =========="

"$PROJECT/venv/bin/python" \
- "$SUMMARY" "$PANEL_SHADOW" "$PUBLISH_SHADOW" <<'PY'
import json
import sys

summary=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

panel=json.load(
    open(
        sys.argv[2],
        encoding="utf-8",
    )
)

publish=json.load(
    open(
        sys.argv[3],
        encoding="utf-8",
    )
)


assert (
    summary[
        "mode"
    ]
    == "shadow_only"
)

assert (
    panel[
        "production_wiring"
    ]
    is False
)

assert (
    publish[
        "production_wiring"
    ]
    is False
)


for value in summary[
    "production"
].values():

    assert value is False


assert (
    panel[
        "current_config_count"
    ]
    > 0
)

assert (
    publish[
        "publishable_count"
    ]
    >= 0
)


panel_counts=panel[
    "counts"
]

assert (
    panel_counts.get(
        "resolved",
        0,
    )
    + panel_counts.get(
        "unknown",
        0,
    )
    + panel_counts.get(
        "conflict",
        0,
    )
    ==
    panel[
        "current_config_count"
    ]
)


assert (
    publish[
        "resolved"
    ]
    + publish[
        "unknown"
    ]
    + publish[
        "conflict"
    ]
    ==
    publish[
        "publishable_count"
    ]
)


print("SHADOW_INTEGRATION_VALID")

print(
    "PANEL_RESOLVED_PERCENT=",
    summary[
        "panel"
    ][
        "resolved_percent"
    ],
)

print(
    "PUBLISH_RESOLVED_PERCENT=",
    summary[
        "publish"
    ][
        "resolved_percent"
    ],
)

print(
    "CONFIG_STORE_KNOWN=",
    summary[
        "panel"
    ][
        "config_store_known"
    ],
)

print(
    "PROJECTION_RECOVERS_MISSING=",
    summary[
        "panel"
    ][
        "projection_recovers_missing"
    ],
)

print(
    "COUNTRY_GROUP_COUNT=",
    summary[
        "publish"
    ][
        "country_group_count"
    ],
)
PY


################################################
# 10 FINAL
################################################

echo
echo "========== [10/10] FINAL =========="

for UNIT in \
  config-location-country-worker.service \
  config-location-country-event-consumer.service
do

    echo \
    "$UNIT ACTIVE=$(systemctl is-active "$UNIT" 2>/dev/null || true) ENABLED=$(systemctl is-enabled "$UNIT" 2>/dev/null || true)"
done


echo "PANEL_SHADOW_READ_MODEL=READY"
echo "PUBLISH_SHADOW_READ_MODEL=READY"

echo "PUBLISHABLE_FILTER_REUSED=YES"
echo "UNKNOWN_GROUP_ISOLATED=YES"
echo "CONFLICT_GROUP_ISOLATED=YES"

echo "PRODUCTION_PANEL_WIRING=NO"
echo "PRODUCTION_PUBLISH_WIRING=NO"
echo "ENDPOINT_MUTATION=NO"

echo "CONFIG_WRITE=NO"
echo "COUNTRY_STORE_WRITE=NO"
echo "ORPHAN_DELETE=NO"
echo "SERVICE_RESTART=NO"

echo
echo "PHASE5_PASS5_SUCCESS"

RESULT="SUCCESS"
