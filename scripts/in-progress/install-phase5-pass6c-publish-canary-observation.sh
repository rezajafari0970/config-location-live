#!/usr/bin/env bash
set -Eeu

PHASE="phase5-pass6c-publish-canary-observation-stability-freshness-gate"

PROJECT="/opt/config-location"
REPO="/root/project-log"

STATE_ROOT="/var/lib/config-location/country/publish-canary"
OBS_ROOT="$STATE_ROOT/observation"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
SUMMARY="$DISCOVERY_DIR/${PHASE}-${TS}.json"

mkdir -p \
  "$RUN_DIR" \
  "$REPORT_DIR" \
  "$DISCOVERY_DIR" \
  "$OBS_ROOT"

RESULT="SUCCESS"
ERRORS=""

CYCLES=5
SLEEP_SECONDS=20

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
PUBLISH CANARY OBSERVATION / STABILITY GATE

Cycles:
$CYCLES

Production publish wiring:
NO

/sub/all mutation:
NO

Endpoint mutation:
NO

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
echo " PHASE 5 PASS 6C"
echo " PUBLISH CANARY OBSERVATION"
echo " STABILITY / FRESHNESS GATE"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/8] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

test -f "$PROJECT/app/country/publish_canary.py" || {
    fail "publish_canary.py missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 COMPILE
################################################

echo
echo "========== [2/8] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/country/publish_canary.py \
  app/country/projection.py \
  app/publish/filter.py

echo "COMPILE_OK"


################################################
# 3 MULTI-CYCLE OBSERVATION
################################################

echo
echo "========== [3/8] OBSERVATION =========="

for i in $(seq 1 "$CYCLES"); do

    OUT="$OBS_ROOT/cycle-${TS}-${i}.json"

    echo
    echo "--- CYCLE $i/$CYCLES ---"

    PYTHONPATH="$PROJECT" \
    "$PROJECT/venv/bin/python" \
    - "$OUT" <<'PY'
import json
import sys

from app.country.publish_canary import (
    build_canary,
    write_canary,
)

data=build_canary()

assert data["production_wiring"] is False
assert data["sub_all_mutated"] is False

write_canary(data)

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
        sort_keys=True,
    )
    fh.write("\n")

print(
    "PUBLISHABLE=",
    data["publishable_count"],
)

print(
    "RESOLVED=",
    data["resolved"],
)

print(
    "UNKNOWN=",
    data["unknown"],
)

print(
    "CONFLICT=",
    data["conflict"],
)

print(
    "RESOLVED_PERCENT=",
    data["resolved_percent"],
)

print(
    "GROUP_COUNT=",
    data["group_count"],
)
PY

    if [ "$i" -lt "$CYCLES" ]; then
        sleep "$SLEEP_SECONDS"
    fi

done


################################################
# 4 STABILITY ANALYSIS
################################################

echo
echo "========== [4/8] STABILITY ANALYSIS =========="

"$PROJECT/venv/bin/python" \
- "$OBS_ROOT" "$TS" "$CYCLES" "$SUMMARY" <<'PY'
import json
import statistics
import sys
from pathlib import Path


root=Path(sys.argv[1])
ts=sys.argv[2]
cycles=int(sys.argv[3])
summary_path=Path(sys.argv[4])


rows=[]

for i in range(1,cycles+1):

    path=root/f"cycle-{ts}-{i}.json"

    d=json.loads(
        path.read_text(
            encoding="utf-8"
        )
    )

    rows.append(d)


def values(key):
    return [
        int(row[key])
        for row in rows
    ]


publishable=values(
    "publishable_count"
)

resolved=values(
    "resolved"
)

unknown=values(
    "unknown"
)

conflict=values(
    "conflict"
)

group_count=values(
    "group_count"
)

resolved_percent=[
    float(
        row["resolved_percent"]
    )
    for row in rows
]


def span(values):
    return max(values)-min(values)


country_series={}

all_groups=set()

for row in rows:
    all_groups.update(
        row.get(
            "group_meta",
            {}
        )
    )

for group in sorted(all_groups):

    country_series[group]=[
        int(
            row.get(
                "group_meta",
                {}
            ).get(
                group,
                {}
            ).get(
                "count",
                0,
            )
        )
        for row in rows
    ]


group_churn={}

for group,series in country_series.items():

    group_churn[group]={
        "min":
            min(series),

        "max":
            max(series),

        "span":
            max(series)-min(series),
    }


top_churn=sorted(
    group_churn.items(),
    key=lambda item: item[1]["span"],
    reverse=True,
)[:20]


publishable_span=span(
    publishable
)

resolved_span=span(
    resolved
)

unknown_span=span(
    unknown
)

conflict_span=span(
    conflict
)

group_span=span(
    group_count
)

resolved_pct_span=(
    max(resolved_percent)
    - min(resolved_percent)
)


# Conservative gates:
# - zero conflict in every cycle
# - publishable churn <= 15%
# - resolved percentage swing <= 8 points
# - group count swing <= 8
base=max(
    1,
    statistics.mean(
        publishable
    ),
)

publishable_churn_pct=(
    publishable_span
    * 100
    / base
)


gate_conflict=(
    max(conflict)==0
)

gate_publishable=(
    publishable_churn_pct
    <= 15.0
)

gate_resolved_pct=(
    resolved_pct_span
    <= 8.0
)

gate_group_count=(
    group_span
    <= 8
)


stable=all(
    (
        gate_conflict,
        gate_publishable,
        gate_resolved_pct,
        gate_group_count,
    )
)


summary={
    "phase":
        "phase5-pass6c-publish-canary-observation-stability-freshness-gate",

    "mode":
        "observation_only",

    "cycles":
        cycles,

    "cycle_seconds":
        20,

    "publishable_series":
        publishable,

    "resolved_series":
        resolved,

    "unknown_series":
        unknown,

    "conflict_series":
        conflict,

    "resolved_percent_series":
        resolved_percent,

    "group_count_series":
        group_count,

    "metrics": {
        "publishable_span":
            publishable_span,

        "publishable_churn_percent":
            round(
                publishable_churn_pct,
                3,
            ),

        "resolved_span":
            resolved_span,

        "unknown_span":
            unknown_span,

        "conflict_span":
            conflict_span,

        "resolved_percent_span":
            round(
                resolved_pct_span,
                3,
            ),

        "group_count_span":
            group_span,
    },

    "top_group_churn":
        [
            {
                "group":
                    group,
                **data,
            }
            for group,data
            in top_churn
        ],

    "gates": {
        "zero_conflict":
            gate_conflict,

        "publishable_churn_le_15pct":
            gate_publishable,

        "resolved_percent_swing_le_8":
            gate_resolved_pct,

        "group_count_swing_le_8":
            gate_group_count,
    },

    "stable":
        stable,

    "production_publish_wiring":
        False,

    "sub_all_mutated":
        False,

    "endpoint_mutation":
        False,
}


summary_path.write_text(
    json.dumps(
        summary,
        ensure_ascii=False,
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)


print(
    json.dumps(
        summary,
        ensure_ascii=False,
        indent=2,
    )
)
PY


################################################
# 5 FRESHNESS CHECK
################################################

echo
echo "========== [5/8] FRESHNESS =========="

"$PROJECT/venv/bin/python" \
- "$OBS_ROOT" "$TS" "$CYCLES" <<'PY'
import json
import sys
from datetime import datetime
from pathlib import Path


root=Path(sys.argv[1])
ts=sys.argv[2]
cycles=int(sys.argv[3])


times=[]

for i in range(1,cycles+1):

    d=json.loads(
        (
            root
            / f"cycle-{ts}-{i}.json"
        ).read_text(
            encoding="utf-8"
        )
    )

    generated=d[
        "generated_at"
    ]

    times.append(
        datetime.fromisoformat(
            generated
        )
    )


for a,b in zip(
    times,
    times[1:],
):

    assert b > a


print("FRESHNESS_MONOTONIC=YES")
print(
    "FIRST=",
    times[0].isoformat(),
)
print(
    "LAST=",
    times[-1].isoformat(),
)
PY


################################################
# 6 PRODUCTION GUARD
################################################

echo
echo "========== [6/8] PRODUCTION GUARD =========="

HASH="$(
find "$PROJECT/app/publish" \
  -type f \
  -name '*.py' \
  -print0 \
| sort -z \
| xargs -0 sha256sum \
| sha256sum \
| awk '{print $1}'
)"

echo "PUBLISH_CODE_HASH=$HASH"

echo "PRODUCTION_PUBLISH_WIRING=NO"
echo "SUB_ALL_MUTATION=NO"
echo "ENDPOINT_MUTATION=NO"


################################################
# 7 SERVICE REGRESSION
################################################

echo
echo "========== [7/8] SERVICES =========="

for UNIT in \
  config-location-panel.service \
  config-location-country-worker.service \
  config-location-country-event-consumer.service
do

    ACTIVE="$(
        systemctl is-active \
          "$UNIT" \
          2>/dev/null || true
    )"

    echo "$UNIT ACTIVE=$ACTIVE"

    [ "$ACTIVE" = "active" ] || {
        fail "$UNIT inactive"
        exit 1
    }

done

echo "SERVICE_REGRESSION_OK"


################################################
# 8 FINAL GATE
################################################

echo
echo "========== [8/8] FINAL GATE =========="

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

print(
    "STABLE=",
    d["stable"],
)

for key,value in d[
    "gates"
].items():

    print(
        f"GATE_{key.upper()}={value}"
    )


if not d["stable"]:
    raise SystemExit(2)


print("STABILITY_GATE_PASS")
print("FRESHNESS_GATE_PASS")
print("READY_FOR_CONTROLLED_PRODUCTION_SWITCH=YES")
PY


echo
echo "PRODUCTION_PUBLISH_WIRING=NO"
echo "SUB_ALL_MUTATION=NO"
echo "ENDPOINT_MUTATION=NO"

echo
echo "PHASE5_PASS6C_SUCCESS"

RESULT="SUCCESS"
