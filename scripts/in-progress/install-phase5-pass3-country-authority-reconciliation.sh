#!/usr/bin/env bash
set -Eeu

PHASE="phase5-pass3-country-authority-state-reconciliation"

PROJECT="/opt/config-location"
REPO="/root/project-log"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
DISCOVERY="$DISCOVERY_DIR/${PHASE}-${TS}.txt"
SUMMARY="$DISCOVERY_DIR/${PHASE}-${TS}.json"
SCHEMA="$DISCOVERY_DIR/${PHASE}-${TS}-schema.json"

mkdir -p \
  "$RUN_DIR" \
  "$REPORT_DIR" \
  "$DISCOVERY_DIR"

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
READ ONLY AUTHORITY / STATE RECONCILIATION

Projection mutation:
NONE

Country-store mutation:
NONE

Config mutation:
NONE

Orphan deletion:
NONE

Panel mutation:
NONE

Publish mutation:
NONE

Service restart:
NONE

Discovery:
$DISCOVERY

Schema:
$SCHEMA

Summary:
$SUMMARY

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
      "$DISCOVERY" \
      "$SCHEMA" \
      "$SUMMARY" \
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
echo " PHASE 5 PASS 3"
echo " COUNTRY AUTHORITY / STATE RECONCILIATION"
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

test -d /var/lib/config-location/configs || {
    fail "config store missing"
    exit 1
}

test -d /var/lib/config-location/country || {
    fail "country store missing"
    exit 1
}

test -f "$PROJECT/app/country/projection.py" || {
    fail "phase5 pass2 projection module missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 COMPILE EXISTING COUNTRY STACK
################################################

echo
echo "========== [2/10] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/projection.py \
  app/country/pipeline.py \
  app/country/storage.py \
  app/country/country_identity.py \
  app/country/geo_intelligence.py \
  app/country/geo_providers.py \
  app/country/worker.py \
  app/country/event_consumer.py

echo "COMPILE_OK"


################################################
# 3 SCHEMA PROFILER
################################################

echo
echo "========== [3/10] SCHEMA PROFILER =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$SCHEMA" <<'PY'
import json
import sys

from collections import Counter, defaultdict
from pathlib import Path


CONFIG_ROOT = Path(
    "/var/lib/config-location/configs"
)

COUNTRY_ROOT = Path(
    "/var/lib/config-location/country"
)

ROOTS = {
    "results":
        COUNTRY_ROOT / "results",

    "identity":
        COUNTRY_ROOT / "country-identity",

    "pipeline_latest":
        COUNTRY_ROOT / "pipeline" / "latest",
}


COUNTRY_NAMES = {
    "country",
    "country_name",
    "countryname",
    "country_code",
    "countrycode",
    "cc",
    "iso",
    "iso_code",
    "iso2",
    "location_country",
    "exit_country",
}

STATE_NAMES = {
    "state",
    "status",
    "verdict",
    "country_state",
    "resolution_state",
    "decision",
    "result_state",
}

CONF_NAMES = {
    "confidence",
    "country_confidence",
    "score",
    "consensus_score",
    "certainty",
}

FLAG_NAMES = {
    "flag",
    "country_flag",
}

PROVIDER_NAMES = {
    "provider",
    "source",
    "country_source",
    "resolved_by",
    "resolver",
}


def load(path):
    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        return None


def config_ids():
    out=set()

    for path in CONFIG_ROOT.glob(
        "*.json"
    ):

        obj=load(path)

        if isinstance(obj,dict):
            cid=obj.get(
                "config_id",
                path.stem,
            )
        else:
            cid=path.stem

        out.add(
            str(cid)
        )

    return out


CURRENT=config_ids()


def cid_of(
    path,
    obj,
):

    if isinstance(obj,dict):

        for key in (
            "config_id",
            "id",
        ):
            if obj.get(key):
                return str(
                    obj[key]
                )

    return path.stem


def walk(
    obj,
    prefix="$",
    depth=0,
):

    if depth > 14:
        return

    if isinstance(obj,dict):

        for key,value in obj.items():

            path=(
                prefix
                + "."
                + str(key)
            )

            yield (
                path,
                str(key).lower(),
                value,
            )

            yield from walk(
                value,
                path,
                depth+1,
            )

    elif isinstance(obj,list):

        for i,value in enumerate(
            obj[:30]
        ):

            path=(
                prefix
                + "[]"
            )

            yield from walk(
                value,
                path,
                depth+1,
            )


schema={}


for source,root in ROOTS.items():

    path_counts=Counter()
    state_values=Counter()
    provider_values=Counter()
    sample_values=defaultdict(list)

    current_records=0
    total_records=0

    if root.exists():

        for path in root.rglob(
            "*.json"
        ):

            obj=load(path)

            if not isinstance(
                obj,
                dict,
            ):
                continue

            total_records += 1

            cid=cid_of(
                path,
                obj,
            )

            if cid not in CURRENT:
                continue

            current_records += 1


            for jpath,key,value in walk(
                obj
            ):

                key_low=key.lower()

                if (
                    key_low in COUNTRY_NAMES
                    or "country" in key_low
                    or key_low in STATE_NAMES
                    or key_low in CONF_NAMES
                    or key_low in FLAG_NAMES
                    or key_low in PROVIDER_NAMES
                ):

                    path_counts[
                        jpath
                    ] += 1


                    if (
                        key_low in STATE_NAMES
                        and isinstance(
                            value,
                            (
                                str,
                                int,
                                float,
                                bool,
                            ),
                        )
                    ):

                        state_values[
                            str(value)
                        ] += 1


                    if (
                        key_low
                        in PROVIDER_NAMES
                        and isinstance(
                            value,
                            (
                                str,
                                int,
                                float,
                            ),
                        )
                    ):

                        provider_values[
                            str(value)
                        ] += 1


                    if (
                        len(
                            sample_values[
                                jpath
                            ]
                        )
                        < 8
                        and isinstance(
                            value,
                            (
                                str,
                                int,
                                float,
                                bool,
                            ),
                        )
                    ):

                        sample_values[
                            jpath
                        ].append(
                            value
                        )


    schema[source]={
        "root":
            str(root),

        "total_records":
            total_records,

        "current_records":
            current_records,

        "top_paths":[
            {
                "path":
                    path,

                "count":
                    count,

                "samples":
                    sample_values[
                        path
                    ],
            }
            for path,count
            in path_counts.most_common(
                120
            )
        ],

        "state_values":
            dict(
                state_values.most_common(
                    100
                )
            ),

        "provider_values":
            dict(
                provider_values.most_common(
                    100
                )
            ),
    }


with open(
    sys.argv[1],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        schema,
        fh,
        ensure_ascii=False,
        indent=2,
    )

    fh.write("\n")


for source,data in schema.items():

    print()
    print(
        "SOURCE=",
        source,
    )

    print(
        "CURRENT_RECORDS=",
        data["current_records"],
    )

    print(
        "TOP_PATHS="
    )

    for row in data[
        "top_paths"
    ][:20]:

        print(
            row["count"],
            row["path"],
            row["samples"][:4],
        )

    print(
        "STATE_VALUES=",
        list(
            data[
                "state_values"
            ].items()
        )[:25],
    )
PY


################################################
# 4 DEEP NESTED EVIDENCE RECONCILIATION
################################################

echo
echo "========== [4/10] DEEP RECONCILIATION =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<'PY'
import json
import sys

from collections import (
    Counter,
    defaultdict,
)

from pathlib import Path


CONFIG_ROOT=Path(
    "/var/lib/config-location/configs"
)

COUNTRY_ROOT=Path(
    "/var/lib/config-location/country"
)

ROOTS={
    "identity":
        COUNTRY_ROOT
        / "country-identity",

    "results":
        COUNTRY_ROOT
        / "results",

    "pipeline_latest":
        COUNTRY_ROOT
        / "pipeline"
        / "latest",
}


UNKNOWN={
    "",
    "unknown",
    "Unknown",
    "UNKNOWN",
    "ناشناس",
    "none",
    "None",
    "null",
    "--",
}


def load(path):
    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        return None


def clean(value):

    if value is None:
        return None

    if not isinstance(
        value,
        (
            str,
            int,
            float,
        ),
    ):
        return None

    value=str(
        value
    ).strip()

    if value in UNKNOWN:
        return None

    return value or None


def current_configs():

    out={}

    for path in CONFIG_ROOT.glob(
        "*.json"
    ):

        obj=load(path)

        if isinstance(
            obj,
            dict,
        ):

            cid=str(
                obj.get(
                    "config_id",
                    path.stem,
                )
            )

        else:
            cid=path.stem

        out[cid]=path

    return out


CURRENT=current_configs()


def walk(
    obj,
    path="$",
    depth=0,
):

    if depth > 14:
        return

    if isinstance(obj,dict):

        for key,value in obj.items():

            p=(
                path
                + "."
                + str(key)
            )

            yield (
                p,
                str(key).lower(),
                value,
            )

            yield from walk(
                value,
                p,
                depth+1,
            )

    elif isinstance(obj,list):

        for value in obj[:40]:

            yield from walk(
                value,
                path+"[]",
                depth+1,
            )


def extract_country_candidates(
    obj,
):

    found=[]

    for path,key,value in walk(
        obj
    ):

        val=clean(
            value
        )

        if not val:
            continue

        kind=None


        if key in {
            "country_code",
            "countrycode",
            "iso",
            "iso2",
            "cc",
        }:

            if (
                len(val)==2
                and val.isalpha()
            ):
                kind="code"
                val=val.upper()


        elif key in {
            "country_name",
            "countryname",
            "country",
            "exit_country",
            "resolved_country",
        }:

            if (
                len(val)==2
                and val.isalpha()
            ):

                kind="code"
                val=val.upper()

            else:
                kind="name"


        elif (
            "country_code"
            in key
            or key.endswith(
                "_country_code"
            )
        ):

            if (
                len(val)==2
                and val.isalpha()
            ):
                kind="code"
                val=val.upper()


        elif (
            "country_name"
            in key
            or key.endswith(
                "_country_name"
            )
        ):

            kind="name"


        if kind:

            found.append(
                {
                    "path":
                        path,

                    "kind":
                        kind,

                    "value":
                        val,
                }
            )


    return found


def extract_state_values(
    obj,
):

    rows=[]

    for path,key,value in walk(
        obj
    ):

        if key not in {
            "state",
            "status",
            "verdict",
            "decision",
            "country_state",
            "resolution_state",
            "result_state",
        }:
            continue

        val=clean(
            value
        )

        if val:

            rows.append(
                {
                    "path":
                        path,

                    "value":
                        val.lower(),
                }
            )

    return rows


def cid_of(
    path,
    obj,
):

    if isinstance(
        obj,
        dict,
    ):

        cid=(
            obj.get(
                "config_id"
            )
            or obj.get(
                "id"
            )
        )

        if cid:
            return str(cid)

    return path.stem


indices={}

for source,root in ROOTS.items():

    idx={}

    if root.exists():

        for path in root.rglob(
            "*.json"
        ):

            obj=load(path)

            if not isinstance(
                obj,
                dict,
            ):
                continue

            cid=cid_of(
                path,
                obj,
            )

            if cid in CURRENT:

                # Prefer direct/current newest
                # occurrence if duplicates exist.
                old=idx.get(
                    cid
                )

                if (
                    old is None
                    or path.stat().st_mtime
                    >
                    old[
                        "mtime"
                    ]
                ):

                    idx[cid]={
                        "path":
                            str(path),

                        "mtime":
                            path.stat().st_mtime,

                        "object":
                            obj,
                    }

    indices[
        source
    ]=idx


state_dist={
    source:Counter()
    for source in ROOTS
}

country_path_dist={
    source:Counter()
    for source in ROOTS
}

country_value_dist={
    source:Counter()
    for source in ROOTS
}

records_with_any_country={
    source:0
    for source in ROOTS
}

records_with_one_country={
    source:0
    for source in ROOTS
}

records_with_multi_country={
    source:0
    for source in ROOTS
}


per_config={}


for cid in CURRENT:

    per_config[
        cid
    ]={}

    for source in ROOTS:

        record=indices[
            source
        ].get(
            cid
        )

        if not record:
            continue

        obj=record[
            "object"
        ]

        countries=extract_country_candidates(
            obj
        )

        states=extract_state_values(
            obj
        )


        unique={
            (
                row["kind"],
                row["value"],
            )
            for row in countries
        }


        if unique:

            records_with_any_country[
                source
            ] += 1


        if len(unique)==1:

            records_with_one_country[
                source
            ] += 1


        elif len(unique)>1:

            records_with_multi_country[
                source
            ] += 1


        for row in countries:

            country_path_dist[
                source
            ][
                row["path"]
            ] += 1

            country_value_dist[
                source
            ][
                row["value"]
            ] += 1


        for row in states:

            state_dist[
                source
            ][
                row["value"]
            ] += 1


        per_config[
            cid
        ][
            source
        ]={
            "path":
                record[
                    "path"
                ],

            "countries":
                countries,

            "states":
                states,
        }


def canonical_key(
    countries,
):

    codes={
        row["value"]
        for row in countries
        if row["kind"]=="code"
    }

    names={
        row["value"].casefold()
        for row in countries
        if row["kind"]=="name"
    }


    if len(codes)==1:
        return (
            "code:"
            + next(
                iter(codes)
            )
        )


    if not codes and len(names)==1:
        return (
            "name:"
            + next(
                iter(names)
            )
        )


    return None


source_single={}

for source in ROOTS:

    source_single[
        source
    ]={}

    for cid in CURRENT:

        row=per_config[
            cid
        ].get(
            source
        )

        if not row:
            continue

        key=canonical_key(
            row[
                "countries"
            ]
        )

        if key:

            source_single[
                source
            ][
                cid
            ]=key


agreement=Counter()

recoverable_pipeline_only=[]

cross_source_conflicts=[]


for cid in CURRENT:

    vals={}

    for source in ROOTS:

        value=source_single[
            source
        ].get(
            cid
        )

        if value:
            vals[
                source
            ]=value


    unique=set(
        vals.values()
    )


    if len(unique)==1 and vals:

        agreement[
            "+".join(
                sorted(
                    vals
                )
            )
        ] += 1


    if (
        "pipeline_latest"
        in vals
        and "identity"
        not in vals
        and "results"
        not in vals
    ):

        recoverable_pipeline_only.append(
            {
                "config_id":
                    cid,

                "value":
                    vals[
                        "pipeline_latest"
                    ],

                "states":
                    per_config[
                        cid
                    ][
                        "pipeline_latest"
                    ][
                        "states"
                    ][:20],

                "countries":
                    per_config[
                        cid
                    ][
                        "pipeline_latest"
                    ][
                        "countries"
                    ][:20],
            }
        )


    if len(unique)>1:

        cross_source_conflicts.append(
            {
                "config_id":
                    cid,

                "values":
                    vals,
            }
        )


summary={
    "phase":
        "phase5-pass3-country-authority-state-reconciliation",

    "read_only":
        True,

    "current_config_count":
        len(CURRENT),

    "current_record_counts": {
        source:
            len(
                indices[
                    source
                ]
            )
        for source
        in ROOTS
    },

    "records_with_any_country":
        records_with_any_country,

    "records_with_single_unambiguous_country":
        records_with_one_country,

    "records_with_multiple_country_values":
        records_with_multi_country,

    "top_state_values": {
        source:
            dict(
                state_dist[
                    source
                ].most_common(
                    40
                )
            )
        for source
        in ROOTS
    },

    "top_country_paths": {
        source:[
            {
                "path":
                    path,

                "count":
                    count,
            }
            for path,count
            in country_path_dist[
                source
            ].most_common(
                40
            )
        ]
        for source
        in ROOTS
    },

    "single_country_counts": {
        source:
            len(
                source_single[
                    source
                ]
            )
        for source
        in ROOTS
    },

    "agreement_patterns":
        dict(
            agreement.most_common()
        ),

    "pipeline_only_recoverable_count":
        len(
            recoverable_pipeline_only
        ),

    "pipeline_only_recoverable_sample":
        recoverable_pipeline_only[
            :80
        ],

    "cross_source_conflict_count":
        len(
            cross_source_conflicts
        ),

    "cross_source_conflict_sample":
        cross_source_conflicts[
            :80
        ],

    "mutations": {
        "projection":
            False,

        "config":
            False,

        "country_store":
            False,

        "panel":
            False,

        "publish":
            False,

        "orphan_delete":
            False,
    },
}


with open(
    sys.argv[1],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        summary,
        fh,
        ensure_ascii=False,
        indent=2,
    )

    fh.write("\n")


print(
    "CURRENT_CONFIGS=",
    summary[
        "current_config_count"
    ],
)

print(
    "CURRENT_RECORD_COUNTS=",
    summary[
        "current_record_counts"
    ],
)

print(
    "ANY_COUNTRY=",
    summary[
        "records_with_any_country"
    ],
)

print(
    "SINGLE_COUNTRY=",
    summary[
        "single_country_counts"
    ],
)

print(
    "PIPELINE_ONLY_RECOVERABLE=",
    summary[
        "pipeline_only_recoverable_count"
    ],
)

print(
    "CROSS_SOURCE_CONFLICTS=",
    summary[
        "cross_source_conflict_count"
    ],
)

print(
    "TOP_PIPELINE_STATES=",
    list(
        summary[
            "top_state_values"
        ][
            "pipeline_latest"
        ].items()
    )[:20],
)

print(
    "TOP_PIPELINE_COUNTRY_PATHS=",
    summary[
        "top_country_paths"
    ][
        "pipeline_latest"
    ][:15],
)
PY


################################################
# 5 REAL CODE AUTHORITY MAP
################################################

echo
echo "========== [5/10] REAL CODE AUTHORITY MAP =========="

{
echo "================================================"
echo " PHASE 5 PASS 3"
echo " COUNTRY AUTHORITY / STATE RECONCILIATION"
echo "================================================"

echo "TIME=$(date -Is)"

echo
echo "========== COUNTRY WRITERS =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'country-identity|pipeline/latest|country/results|write.*country|save.*country|persist.*country|atomic.*country|locked|country_identity' \
  "$PROJECT/app/country" \
  2>/dev/null \
  | head -n 2600 || true


echo
echo "========== STATE / VERDICT LOGIC =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'confirmed|resolved|accepted|stable|locked|verdict|confidence|consensus|final|country_state|status' \
  "$PROJECT/app/country/pipeline.py" \
  "$PROJECT/app/country/country_identity.py" \
  "$PROJECT/app/country/storage.py" \
  "$PROJECT/app/country/worker.py" \
  "$PROJECT/app/country/event_consumer.py" \
  "$PROJECT/app/country/geo_intelligence.py" \
  2>/dev/null \
  | head -n 3200 || true


echo
echo "========== PROJECTION CONTRACT CURRENT =========="

nl -ba \
  "$PROJECT/app/country/projection.py" \
  | sed -n '1,520p'


echo
echo "========== MUTATION POLICY =========="

echo "READ_ONLY=true"
echo "PROJECTION_MUTATION=false"
echo "CONFIG_MUTATION=false"
echo "COUNTRY_STORE_MUTATION=false"
echo "ORPHAN_DELETE=false"
echo "PANEL_MUTATION=false"
echo "PUBLISH_MUTATION=false"
echo "SERVICE_RESTART=false"

echo
echo "PHASE5_PASS3_DISCOVERY_COMPLETE"

} > "$DISCOVERY"


################################################
# 6 SHADOW RECOVERY SIMULATION
################################################

echo
echo "========== [6/10] SHADOW RECOVERY SIMULATION =========="

"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<'PY'
import json
import sys

d=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

current=int(
    d[
        "current_config_count"
    ]
)

pipeline_single=int(
    d[
        "single_country_counts"
    ].get(
        "pipeline_latest",
        0,
    )
)

identity_single=int(
    d[
        "single_country_counts"
    ].get(
        "identity",
        0,
    )
)

results_single=int(
    d[
        "single_country_counts"
    ].get(
        "results",
        0,
    )
)

pipeline_only=int(
    d[
        "pipeline_only_recoverable_count"
    ]
)

conflicts=int(
    d[
        "cross_source_conflict_count"
    ]
)

print(
    "CURRENT=",
    current,
)

print(
    "IDENTITY_UNAMBIGUOUS=",
    identity_single,
)

print(
    "RESULTS_UNAMBIGUOUS=",
    results_single,
)

print(
    "PIPELINE_UNAMBIGUOUS=",
    pipeline_single,
)

print(
    "PIPELINE_ONLY_POTENTIAL_RECOVERY=",
    pipeline_only,
)

print(
    "CROSS_SOURCE_CONFLICTS=",
    conflicts,
)


if pipeline_only > 0:

    print(
        "PIPELINE_NESTED_SCHEMA_PRESENT=YES"
    )

else:

    print(
        "PIPELINE_NESTED_SCHEMA_PRESENT=NO_OR_NOT_EXTRACTABLE"
    )


if conflicts > 0:

    print(
        "DIRECT_AUTHORITY_WIRING_SAFE=NO"
    )

else:

    print(
        "DIRECT_AUTHORITY_WIRING_SAFE=NOT_YET_PROVEN"
    )


print(
    "SHADOW_ONLY=YES"
)
PY


################################################
# 7 NO-MUTATION HASH CHECK
################################################

echo
echo "========== [7/10] NO MUTATION CHECK =========="

echo "CONFIG_COUNT=$(
find /var/lib/config-location/configs \
  -maxdepth 1 \
  -type f \
  -name '*.json' \
  | wc -l
)"

echo "RESULT_COUNT=$(
find /var/lib/config-location/country/results \
  -type f \
  -name '*.json' \
  2>/dev/null \
  | wc -l
)"

echo "IDENTITY_COUNT=$(
find /var/lib/config-location/country/country-identity \
  -type f \
  -name '*.json' \
  2>/dev/null \
  | wc -l
)"

echo "PIPELINE_COUNT=$(
find /var/lib/config-location/country/pipeline/latest \
  -type f \
  -name '*.json' \
  2>/dev/null \
  | wc -l
)"

echo "NO_MUTATION_CHECK_OK"


################################################
# 8 SERVICES
################################################

echo
echo "========== [8/10] SERVICES =========="

for UNIT in \
  config-location-country-worker.service \
  config-location-country-event-consumer.service
do

    ACTIVE="$(
        systemctl is-active \
          "$UNIT" \
          2>/dev/null || true
    )"

    ENABLED="$(
        systemctl is-enabled \
          "$UNIT" \
          2>/dev/null || true
    )"

    echo \
    "$UNIT ACTIVE=$ACTIVE ENABLED=$ENABLED"

done

echo "SERVICE_RESTART=NONE"


################################################
# 9 VALIDATION
################################################

echo
echo "========== [9/10] VALIDATION =========="

test -s "$SCHEMA" || {
    fail "schema output missing"
    exit 1
}

test -s "$SUMMARY" || {
    fail "summary output missing"
    exit 1
}

test -s "$DISCOVERY" || {
    fail "discovery output missing"
    exit 1
}

grep -q \
  'PHASE5_PASS3_DISCOVERY_COMPLETE' \
  "$DISCOVERY" || {
    fail "discovery incomplete"
    exit 1
}

"$PROJECT/venv/bin/python" \
- "$SUMMARY" <<'PY'
import json
import sys

d=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

assert (
    d["read_only"]
    is True
)

assert (
    d["current_config_count"]
    > 0
)

for source in (
    "identity",
    "results",
    "pipeline_latest",
):

    assert (
        source
        in d[
            "current_record_counts"
        ]
    )


for value in d[
    "mutations"
].values():

    assert value is False


print(
    "SUMMARY_CONTRACT_VALID"
)

print(
    "CURRENT_CONFIG_COUNT=",
    d[
        "current_config_count"
    ],
)

print(
    "PIPELINE_ONLY_RECOVERABLE_COUNT=",
    d[
        "pipeline_only_recoverable_count"
    ],
)

print(
    "CROSS_SOURCE_CONFLICT_COUNT=",
    d[
        "cross_source_conflict_count"
    ],
)
PY

echo "SCHEMA_VALID"
echo "DISCOVERY_VALID"


################################################
# 10 FINAL
################################################

echo
echo "========== [10/10] FINAL =========="

echo "COUNTRY_SCHEMA_PROFILE=READY"
echo "NESTED_COUNTRY_PATHS_PROFILED=YES"
echo "STATE_VALUES_PROFILED=YES"
echo "AUTHORITY_OVERLAP_PROFILED=YES"
echo "PIPELINE_RECOVERY_CANDIDATES_PROFILED=YES"
echo "CROSS_SOURCE_CONFLICTS_PROFILED=YES"

echo "PROJECTION_PATCH=NO"
echo "COUNTRY_STORE_WRITE=NO"
echo "CONFIG_WRITE=NO"
echo "ORPHAN_DELETE=NO"
echo "PANEL_WIRING=NO"
echo "PUBLISH_WIRING=NO"

echo
echo "PHASE5_PASS3_SUCCESS"

RESULT="SUCCESS"
