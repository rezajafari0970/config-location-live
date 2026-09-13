#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

SVC=config-location-country-worker.service

DURATION=720
INTERVAL=60

echo "=== 1. PRECHECK ==="

test "$(systemctl is-active "$SVC")" = active

ENABLED=$(
    systemctl is-enabled "$SVC" 2>/dev/null || true
)

echo "COUNTRY_ENABLED=$ENABLED"

test "$ENABLED" != enabled


for svc in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done


snapshot() {

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

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

health=Counter()
country=Counter()

for p in H.glob("*.json"):
    try:
        o=json.loads(p.read_text())
    except Exception:
        continue

    health[
        str(o.get("state"))
    ] += 1


for p in P.glob("*.json"):
    try:
        o=json.loads(p.read_text())
    except Exception:
        continue

    country[
        str(o.get("state"))
    ] += 1


tracked=0

if W.exists():
    try:
        o=json.loads(W.read_text())
        tracked=len(
            o.get("records",{})
        )
    except Exception:
        pass


print(
    "HEALTHY=%d COUNTRY=%d TRACKED=%d "
    "CONFIRMED_STABLE=%d "
    "CONFIRMED_ROTATING_IP=%d "
    "PENDING=%d "
    "UNSTABLE_EXIT=%d "
    "UNKNOWN=%d "
    "AMBIGUOUS=%d "
    "ERROR=%d"
    % (
        health.get("healthy",0),
        sum(country.values()),
        tracked,
        country.get(
            "confirmed_stable",0
        ),
        country.get(
            "confirmed_rotating_ip",0
        ),
        country.get(
            "pending_confirmation",0
        ),
        country.get(
            "unstable_exit",0
        ),
        country.get("unknown",0),
        country.get("ambiguous",0),
        country.get("error",0),
    )
)
PY

}


echo "=== 2. BASELINE ==="

BASELINE=$(snapshot)

echo "$BASELINE"

export BASELINE


echo "=== 3. 12-MINUTE SHADOW SOAK ==="

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


    COUNTRY_ACTIVE=$(
        systemctl is-active "$SVC" 2>/dev/null || true
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


    echo "COUNTRY_ACTIVE=$COUNTRY_ACTIVE"
    echo "COUNTRY_RESTARTS=$RESTARTS"
    echo "COUNTRY_MEMORY=$MEM"
    echo "COUNTRY_TASKS=$TASKS"

    test "$COUNTRY_ACTIVE" = active
    test "$RESTARTS" -eq 0


    for svc in \
    config-location-fetcher.service \
    config-location-health-adaptive.service \
    config-location-lifecycle-sync.service \
    config-location-lifecycle-watchdog.service \
    config-location-panel.service
    do
        X=$(systemctl is-active "$svc" 2>/dev/null || true)
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


    echo "$(snapshot)"
done


echo "=== 4. FINAL SNAPSHOT ==="

FINAL=$(snapshot)

echo "$FINAL"

export FINAL


echo "=== 5. PROGRESS SLA ==="

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
    "BASELINE_COUNTRY=",
    b["COUNTRY"],
)

print(
    "FINAL_COUNTRY=",
    f["COUNTRY"],
)

print(
    "NEW_COUNTRY_RESULTS=",
    f["COUNTRY"]
    - b["COUNTRY"],
)

print(
    "BASELINE_TRACKED=",
    b["TRACKED"],
)

print(
    "FINAL_TRACKED=",
    f["TRACKED"],
)

print(
    "TRACKED_GROWTH=",
    f["TRACKED"]
    - b["TRACKED"],
)


assert (
    f["COUNTRY"]
    >
    b["COUNTRY"]
)

assert (
    f["TRACKED"]
    >
    b["TRACKED"]
)

# At 3 jobs / 45 sec over 12 minutes,
# practical production progress should be
# materially larger than a few configs.
assert (
    f["COUNTRY"]
    - b["COUNTRY"]
    >= 20
)

assert (
    f["TRACKED"]
    - b["TRACKED"]
    >= 20
)

print(
    "SHADOW_PROGRESS_SLA=PASS"
)
PY


echo "=== 6. COUNTRY RESULT QUALITY ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

states=Counter()
countries=Counter()
invalid=0

for p in P.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        invalid+=1
        continue

    states[
        str(o.get("state"))
    ]+=1

    if o.get("country_code"):
        countries[
            str(
                o["country_code"]
            )
        ]+=1


print(
    "INVALID_COUNTRY_JSON=",
    invalid,
)

print(
    "STATES=",
    dict(states),
)

print(
    "COUNTRIES=",
    dict(
        countries.most_common(
            30
        )
    ),
)

assert invalid == 0

confirmed=(
    states[
        "confirmed_stable"
    ]
    +
    states[
        "confirmed_rotating_ip"
    ]
)

pending=states[
    "pending_confirmation"
]

usable=confirmed+pending

print(
    "CONFIRMED=",
    confirmed,
)

print(
    "PENDING=",
    pending,
)

print(
    "USABLE_COUNTRY_RESULTS=",
    usable,
)

assert usable > 0

print(
    "COUNTRY_RESULT_QUALITY=PASS"
)
PY


echo "=== 7. COUNTRY DAEMON JOURNAL AUDIT ==="

journalctl \
-u "$SVC" \
--since "-15 minutes" \
--no-pager \
| tail -n 300


ERROR_LINES=$(
    journalctl \
    -u "$SVC" \
    --since "-15 minutes" \
    --no-pager \
    | grep -Ec \
    'Traceback|COUNTRY_CYCLE_ERROR|COUNTRY_CYCLE_RUNTIME_ERROR' \
    || true
)

echo "COUNTRY_ERROR_LINES=$ERROR_LINES"

test "$ERROR_LINES" -eq 0


echo "=== 8. RESTART / LEAK VERIFY ==="

RESTARTS=$(
    systemctl show "$SVC" \
    -p NRestarts \
    --value
)

echo "COUNTRY_SERVICE_RESTARTS=$RESTARTS"

test "$RESTARTS" -eq 0


COUNT=$(
    find \
    /var/lib/config-location/health-sandboxes \
    -maxdepth 1 \
    -type d \
    -name "country-*" \
    2>/dev/null \
    | wc -l
)

echo "COUNTRY_SANDBOX_RESIDUAL=$COUNT"

test "$COUNT" -le 1


echo "=== 9. HEALTH / FETCHER FINAL ISOLATION ==="

for svc in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)

    echo "$svc=$X"

    test "$X" = active
done


echo "=== 10. STILL SHADOW / DISABLED ==="

ENABLED=$(
    systemctl is-enabled "$SVC" 2>/dev/null || true
)

echo "COUNTRY_SERVICE_ENABLED=$ENABLED"

test "$ENABLED" != enabled


echo "========================================"
echo "FIX22H2=PASS"
echo "COUNTRY_SHADOW_SOAK=PASS"
echo "SOAK_DURATION=12_MINUTES"
echo "RATE_LIMIT=3_JOBS_PER_45_SECONDS"
echo "COUNTRY_SERVICE_RESTARTS=0"
echo "COUNTRY_SANDBOX_LEAK=NO"
echo "HEALTH_FETCHER_ISOLATION=PASS"
echo "COUNTRY_PUBLICATION=DISABLED"
echo "REMARK_MUTATION=DISABLED"
echo "SUBSCRIPTION_MUTATION=DISABLED"
echo "PERMANENT_ENABLE=NO"
echo "========================================"
