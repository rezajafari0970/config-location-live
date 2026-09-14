#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

C=/var/lib/config-location/configs
H=/var/lib/config-location/health-results/latest

SVC=config-location-health-adaptive.service

DURATION=900
INTERVAL=60

echo "=== PRECHECK ==="

test "$(systemctl is-active "$SVC")" = active

systemctl show "$SVC" \
-p ActiveState \
-p SubState \
-p Result \
-p MainPID \
--no-pager


snapshot() {

"$PY" <<'PY'
from pathlib import Path
import time

C=Path(
    "/var/lib/config-location/configs"
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

health={
    p.stem
    for p in H.glob("*.json")
}

now=time.time()

ages=[
    now-p.stat().st_mtime
    for p in C.glob("*.json")
    if p.stem not in health
]

ages.sort(
    reverse=True
)

print(
    "CONFIGS=",
    len(list(C.glob("*.json"))),
    "HEALTH=",
    len(health),
    "MISSING=",
    len(ages),
    "OLDEST=",
    int(ages[0]) if ages else 0,
    "GT5M=",
    sum(x>=300 for x in ages),
    "GT15M=",
    sum(x>=900 for x in ages),
    "GT30M=",
    sum(x>=1800 for x in ages),
)
PY

}


echo "=== BASELINE ==="

BASE=$(snapshot)

echo "T=0 $BASE"


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

    STATE=$(
        systemctl is-active \
        "$SVC" 2>/dev/null || true
    )

    echo "SERVICE[$N]=$STATE"

    test "$STATE" = active

    SNAP=$(snapshot)

    echo "T=$((N*INTERVAL)) $SNAP"
done


echo "=== FINAL ==="

FINAL=$(snapshot)

echo "$FINAL"


echo "=== SLA VERIFY ==="

export FINAL

"$PY" <<'PY'
import os
import re

s=os.environ["FINAL"]

def get(name):
    m=re.search(
        rf"{name}=\s*(\d+)",
        s,
    )

    if not m:
        raise SystemExit(
            f"missing metric {name}"
        )

    return int(
        m.group(1)
    )

missing=get("MISSING")
oldest=get("OLDEST")
gt15=get("GT15M")
gt30=get("GT30M")

print(
    "FINAL_MISSING=",
    missing,
)

print(
    "FINAL_OLDEST_SECONDS=",
    oldest,
)

print(
    "FINAL_GT15M=",
    gt15,
)

print(
    "FINAL_GT30M=",
    gt30,
)

# Hard SLA:
# No supported config may remain without
# Health for >=30 minutes.
assert gt30 == 0

print(
    "HARD_SLA_30M=PASS"
)

if gt15 == 0:
    print(
        "TARGET_SLA_15M=PASS"
    )
else:
    print(
        "TARGET_SLA_15M=PENDING"
    )
PY


echo "=== RUNTIME RESIDUAL CHECK ==="

RF=$(
    {
        grep -l \
        '"state"[[:space:]]*:[[:space:]]*"runtime_failed"' \
        "$H"/*.json 2>/dev/null \
        || true
    } | wc -l
)

XV=$(
    {
        grep -l \
        'xray_validation_failed' \
        "$H"/*.json 2>/dev/null \
        || true
    } | wc -l
)

echo "RUNTIME_FAILED=$RF"
echo "XRAY_VALIDATION_FAILED=$XV"

test "$RF" -eq 0
test "$XV" -eq 0


echo "=== SERVICE FINAL ==="

STATE=$(systemctl is-active "$SVC")

echo "HEALTH_STATE=$STATE"

test "$STATE" = active


echo "========================================"
echo "FIX20.9D=PASS"
echo "PRODUCTION_COVERAGE_SOAK=PASS"
echo "HARD_SLA_30M=PASS"
echo "RUNTIME_FAILED=0"
echo "XRAY_VALIDATION_FAILED=0"
echo "HEALTH_SERVICE=active"
echo "========================================"
