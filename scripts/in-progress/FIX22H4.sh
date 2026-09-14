#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

SVC=config-location-country-worker.service

DURATION=900
INTERVAL=90


snapshot() {

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

C=Path(
    "/var/lib/config-location/configs"
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

W=Path(
    "/var/lib/config-location/"
    "country/worker/state.json"
)


healthy=set()

for p in H.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    if str(
        o.get("state","")
    ).lower()=="healthy":

        if (
            C
            / f"{p.stem}.json"
        ).exists():

            healthy.add(
                p.stem
            )


states=Counter()

country_for_healthy=0

for cid in healthy:

    p=P/f"{cid}.json"

    if not p.exists():
        continue

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    country_for_healthy += 1

    states[
        str(
            o.get("state")
        )
    ] += 1


tracked=0

if W.exists():

    try:

        worker=json.loads(
            W.read_text()
        )

        tracked=len(
            worker.get(
                "records",
                {}
            )
        )

    except Exception:
        pass


healthy_count=len(
    healthy
)

coverage=(
    country_for_healthy
    / healthy_count
    if healthy_count
    else 0.0
)

confirmed=(
    states[
        "confirmed_stable"
    ]
    +
    states[
        "confirmed_rotating_ip"
    ]
)

usable=(
    confirmed
    +
    states[
        "pending_confirmation"
    ]
)


print(
    "HEALTHY=%d "
    "COUNTRY_FOR_HEALTHY=%d "
    "COVERAGE_BP=%d "
    "TRACKED=%d "
    "CONFIRMED=%d "
    "PENDING=%d "
    "UNSTABLE=%d "
    "UNKNOWN=%d "
    "AMBIGUOUS=%d "
    "ERROR=%d "
    "USABLE=%d"
    % (
        healthy_count,
        country_for_healthy,
        int(
            coverage
            * 10000
        ),
        tracked,
        confirmed,
        states[
            "pending_confirmation"
        ],
        states[
            "unstable_exit"
        ],
        states[
            "unknown"
        ],
        states[
            "ambiguous"
        ],
        states[
            "error"
        ],
        usable,
    )
)
PY

}


echo "=== 1. PRECHECK ==="

ACTIVE=$(
    systemctl is-active "$SVC"
)

ENABLED=$(
    systemctl is-enabled "$SVC"
)

RESTARTS=$(
    systemctl show "$SVC" \
    -p NRestarts \
    --value
)

echo "ACTIVE=$ACTIVE"
echo "ENABLED=$ENABLED"
echo "RESTARTS=$RESTARTS"

test "$ACTIVE" = active
test "$ENABLED" = enabled
test "$RESTARTS" -eq 0


echo "=== 2. BASELINE ==="

BASELINE=$(snapshot)

echo "$BASELINE"

export BASELINE


echo "=== 3. 15-MINUTE CONVERGENCE ==="

START=$(date +%s)
N=0

while true; do

    NOW=$(date +%s)
    ELAPSED=$((NOW-START))

    if [ "$ELAPSED" -ge "$DURATION" ]; then
        break
    fi

    sleep "$INTERVAL"

    N=$((N+1))

    echo
    echo "----- T=$((N*INTERVAL)) -----"

    ACTIVE=$(
        systemctl is-active "$SVC"
    )

    RESTARTS=$(
        systemctl show "$SVC" \
        -p NRestarts \
        --value
    )

    MEM=$(
        systemctl show "$SVC" \
        -p MemoryCurrent \
        --value
    )

    TASKS=$(
        systemctl show "$SVC" \
        -p TasksCurrent \
        --value
    )

    echo "ACTIVE=$ACTIVE"
    echo "RESTARTS=$RESTARTS"
    echo "MEMORY=$MEM"
    echo "TASKS=$TASKS"

    test "$ACTIVE" = active
    test "$RESTARTS" -eq 0


    for svc in \
    config-location-fetcher.service \
    config-location-health-adaptive.service \
    config-location-lifecycle-sync.service \
    config-location-lifecycle-watchdog.service \
    config-location-panel.service
    do

        X=$(
            systemctl is-active \
            "$svc" 2>/dev/null || true
        )

        echo "$svc=$X"

        test "$X" = active
    done


    COUNT=$(
        find \
        /var/lib/config-location/health-sandboxes \
        -maxdepth 1 \
        -type d \
        -name "country-*" \
        2>/dev/null \
        | wc -l
    )

    echo "COUNTRY_SANDBOXES=$COUNT"

    test "$COUNT" -le 1


    snapshot
done


echo "=== 4. FINAL SNAPSHOT ==="

FINAL=$(snapshot)

echo "$FINAL"

export FINAL


echo "=== 5. CONVERGENCE DELTA ==="

"$PY" <<'PY'
import os
import re


def parse(s):

    return {
        k:int(v)
        for k,v in re.findall(
            r"([A-Z_]+)=(\d+)",
            s,
        )
    }


b=parse(
    os.environ["BASELINE"]
)

f=parse(
    os.environ["FINAL"]
)


print(
    "BASELINE_HEALTHY=",
    b["HEALTHY"],
)

print(
    "FINAL_HEALTHY=",
    f["HEALTHY"],
)

print(
    "BASELINE_COUNTRY=",
    b["COUNTRY_FOR_HEALTHY"],
)

print(
    "FINAL_COUNTRY=",
    f["COUNTRY_FOR_HEALTHY"],
)

print(
    "COUNTRY_GROWTH=",
    f["COUNTRY_FOR_HEALTHY"]
    -
    b["COUNTRY_FOR_HEALTHY"],
)

print(
    "BASELINE_COVERAGE_PERCENT=",
    b["COVERAGE_BP"]/100,
)

print(
    "FINAL_COVERAGE_PERCENT=",
    f["COVERAGE_BP"]/100,
)

print(
    "CONFIRMED=",
    f["CONFIRMED"],
)

print(
    "PENDING=",
    f["PENDING"],
)

print(
    "UNSTABLE=",
    f["UNSTABLE"],
)

print(
    "UNKNOWN=",
    f["UNKNOWN"],
)

print(
    "AMBIGUOUS=",
    f["AMBIGUOUS"],
)

print(
    "ERROR=",
    f["ERROR"],
)


assert (
    f["COUNTRY_FOR_HEALTHY"]
    >
    b["COUNTRY_FOR_HEALTHY"]
)

assert (
    f["TRACKED"]
    >=
    b["TRACKED"]
)

assert (
    f["COVERAGE_BP"]
    >
    b["COVERAGE_BP"]
)

print(
    "COVERAGE_CONVERGENCE=PASS"
)
PY


echo "=== 6. RESULT INTEGRITY ==="

"$PY" <<'PY'
from pathlib import Path
import json

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

invalid=0
mismatch=0

for p in P.glob(
    "*.json"
):

    try:

        o=json.loads(
            p.read_text()
        )

    except Exception:

        invalid += 1
        continue


    if str(
        o.get(
            "config_id",
            "",
        )
    ) != p.stem:

        mismatch += 1


print(
    "INVALID_COUNTRY_FILES=",
    invalid,
)

print(
    "COUNTRY_ID_MISMATCH=",
    mismatch,
)

assert invalid == 0
assert mismatch == 0

print(
    "COUNTRY_RESULT_INTEGRITY=PASS"
)
PY


echo "=== 7. ERROR / RESTART AUDIT ==="

RESTARTS=$(
    systemctl show "$SVC" \
    -p NRestarts \
    --value
)

echo "COUNTRY_RESTARTS=$RESTARTS"

test "$RESTARTS" -eq 0


ERROR_LINES=$(
    journalctl \
    -u "$SVC" \
    --since "-17 minutes" \
    --no-pager \
    | grep -Ec \
    'Traceback|COUNTRY_CYCLE_ERROR|COUNTRY_CYCLE_RUNTIME_ERROR' \
    || true
)

echo "DAEMON_ERROR_LINES=$ERROR_LINES"

test "$ERROR_LINES" -eq 0


echo "=== 8. SAFETY FREEZE ==="

"$PY" <<'PY'
from pathlib import Path
import json

o=json.loads(
    Path(
        "/var/lib/config-location/"
        "country/worker-safety.json"
    ).read_text()
)

assert (
    o["publication_enabled"]
    is False
)

assert (
    o["remark_mutation_enabled"]
    is False
)

assert (
    o[
        "subscription_mutation_enabled"
    ]
    is False
)

assert (
    o[
        "source_raw_mutation_enabled"
    ]
    is False
)

print(
    "PUBLICATION_SAFETY=PASS"
)
PY


echo "=== 9. FINAL SERVICE ISOLATION ==="

for svc in \
config-location-country-worker.service \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do

    X=$(
        systemctl is-active \
        "$svc" 2>/dev/null || true
    )

    echo "$svc=$X"

    test "$X" = active
done


echo "========================================"
echo "FIX22H4=PASS"
echo "COUNTRY_COVERAGE_CONVERGENCE=PASS"
echo "PERMANENT_WORKER_STABLE=YES"
echo "COUNTRY_RESULT_INTEGRITY=PASS"
echo "COUNTRY_DAEMON_ERRORS=0"
echo "COUNTRY_SERVICE_RESTARTS=0"
echo "PUBLICATION_STILL_DISABLED=YES"
echo "SOURCE_RAW_UNCHANGED=YES"
echo "========================================"
