#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

D=/var/lib/config-location
C="$D/configs"
H="$D/health-results/latest"
T="$D/health-lifecycle/consecutive-state.json"
Q="$D/health-adaptive/queue-state.json"

DURATION=600
INTERVAL=60

echo "=== PRECHECK ==="

for svc in \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(systemctl is-active "$svc")
    echo "$svc=$X"
    test "$X" = active
done

snapshot() {

"$PY" <<'PY'
import json
from pathlib import Path

C=Path("/var/lib/config-location/configs")
H=Path("/var/lib/config-location/health-results/latest")
T=Path("/var/lib/config-location/health-lifecycle/consecutive-state.json")
Q=Path("/var/lib/config-location/health-adaptive/queue-state.json")

configs={p.stem for p in C.glob("*.json")}
health={p.stem for p in H.glob("*.json")}

tracker_records={}

if T.exists():
    o=json.loads(T.read_text())
    tracker_records=o.get("records",{}) or {}

queue=[]
leases=[]

if Q.exists():
    o=json.loads(Q.read_text())
    queue=o.get("queue",[]) or []
    leases=o.get("leases",[]) or []

orphan_health=len(health-configs)

orphan_tracker=sum(
    1
    for cid in tracker_records
    if cid not in configs
)

orphan_queue=sum(
    1
    for cid in queue
    if cid not in configs
)

orphan_leases=sum(
    1
    for cid in leases
    if cid not in configs
)

print(
    "CONFIGS=%d HEALTH=%d TRACKER=%d "
    "ORPHAN_HEALTH=%d ORPHAN_TRACKER=%d "
    "ORPHAN_QUEUE=%d ORPHAN_LEASES=%d"
    % (
        len(configs),
        len(health),
        len(tracker_records),
        orphan_health,
        orphan_tracker,
        orphan_queue,
        orphan_leases,
    )
)
PY

}

echo "=== BASELINE ==="
echo "T=0 $(snapshot)"

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

    for svc in \
    config-location-fetcher.service \
    config-location-health-adaptive.service \
    config-location-lifecycle-sync.service \
    config-location-lifecycle-watchdog.service
    do
        X=$(systemctl is-active "$svc")
        test "$X" = active
    done

    echo "T=$((N*INTERVAL)) $(snapshot)"
done

echo "=== FINAL ==="

FINAL=$(snapshot)
echo "$FINAL"

export FINAL

"$PY" <<'PY'
import os
import re

s=os.environ["FINAL"]

def n(name):
    m=re.search(
        rf"{name}=(\d+)",
        s,
    )
    if not m:
        raise RuntimeError(name)
    return int(m.group(1))

print("FINAL_CONFIGS=",n("CONFIGS"))
print("FINAL_TRACKER=",n("TRACKER"))
print("ORPHAN_HEALTH=",n("ORPHAN_HEALTH"))
print("ORPHAN_TRACKER=",n("ORPHAN_TRACKER"))
print("ORPHAN_QUEUE=",n("ORPHAN_QUEUE"))
print("ORPHAN_LEASES=",n("ORPHAN_LEASES"))

assert n("ORPHAN_TRACKER") == 0

# Health / queue can have a tiny live race,
# but historical accumulation is forbidden.
assert n("ORPHAN_HEALTH") < 50
assert n("ORPHAN_QUEUE") < 50
assert n("ORPHAN_LEASES") < 50

print("LIFECYCLE_REFERENTIAL_SLA=PASS")
PY

echo "=== POLICY FREEZE ==="

"$PY" <<'PY'
import json
from pathlib import Path

p=Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "safety-latest.json"
)

o=json.loads(p.read_text())

print(
    "CONFIGURED_DELETE=",
    o.get("configured_production_delete"),
)

print(
    "DELETE_ALLOWED=",
    o.get("production_delete_allowed"),
)

assert o.get("configured_production_delete") is False
assert o.get("production_delete_allowed") is False

print("PRODUCTION_DELETE_FREEZE=PASS")
PY

echo "=== SELFTESTS ==="

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.selftest_consecutive

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.selftest_policy

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.selftest_safety_gates

echo "SELFTESTS=PASS"

echo "========================================"
echo "FIX21D=PASS"
echo "PRODUCTION_LIFECYCLE_SOAK=PASS"
echo "ORPHAN_TRACKER=0"
echo "PRODUCTION_DELETE=DISABLED"
echo "LIFECYCLE_SELFTESTS=PASS"
echo "========================================"
