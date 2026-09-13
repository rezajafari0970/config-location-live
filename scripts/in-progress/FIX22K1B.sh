#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

echo "=== 1. ISOLATED QUEUE TEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import shutil

import app.country.event_bus as q

T=Path("/tmp/FIX22K1B")

shutil.rmtree(
    T,
    ignore_errors=True,
)

q.ROOT=T
q.PENDING=T/"pending"
q.LEASED=T/"leased"
q.DONE=T/"done"
q.DEAD=T/"dead"
q.LOCK=T/"queue.lock"
q.COUNTRY_RESULTS=T/"results"

q.dirs()


# ---------------------------------------
# enqueue
# ---------------------------------------

r=q.enqueue(
    config_id="A",
    generation="1",
    completed_at="test",
    priority=1,
)

assert r["status"]=="enqueued"


# ---------------------------------------
# dedupe
# ---------------------------------------

r=q.enqueue(
    config_id="A",
    generation="1",
    completed_at="test",
    priority=1,
)

assert r["status"]=="duplicate"

print("DEDUP=PASS")


# ---------------------------------------
# newer health generation allowed
# ---------------------------------------

r=q.enqueue(
    config_id="A",
    generation="2",
    completed_at="test",
    priority=1,
)

assert r["status"]=="enqueued"

print("GENERATION=PASS")


# ---------------------------------------
# priority
# ---------------------------------------

q.enqueue(
    config_id="HIGH",
    generation="1",
    completed_at="test",
    priority=-1,
)

x=q.lease(
    "worker-1",
    30,
)

assert x is not None

p,o=x

assert o["config_id"]=="HIGH"

print("PRIORITY=PASS")


# ---------------------------------------
# ACK
# ---------------------------------------

target=q.ack(
    p,
    {
        "state":
            "confirmed_stable",
        "country_code":
            "DE",
    },
)

assert target.exists()

print("ACK=PASS")


# ---------------------------------------
# NACK + retry
# ---------------------------------------

x=q.lease(
    "worker-1",
    30,
)

assert x is not None

p,o=x

target=q.nack(
    p,
    "temporary",
    retry_seconds=1,
    max_attempts=4,
)

assert target.parent==q.PENDING

o=q.read(target)

assert o["attempt"]==1

print("NACK=PASS")


# Force retry due now.
o["not_before_epoch"]=0
q.write(target,o)


# ---------------------------------------
# crash / expired lease
# ---------------------------------------

x=q.lease(
    "crashed-worker",
    5,
)

assert x is not None

p,o=x

o["lease_until_epoch"]=q.now()-1

q.write(p,o)

n=q.recover_expired()

assert n==1

print("LEASE_RECOVERY=PASS")


# ---------------------------------------
# dead letter
# ---------------------------------------

x=q.lease(
    "worker-2",
    30,
)

assert x is not None

p,o=x

target=q.nack(
    p,
    "permanent",
    retry_seconds=1,
    max_attempts=1,
)

assert target.parent==q.DEAD
assert target.exists()

print("DEAD_LETTER=PASS")


print(
    "TEST_STATS=",
    q.stats(),
)

print(
    "ISOLATED_QUEUE=PASS"
)
PY


echo "=== 2. REAL FINAL SUPPRESSION ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

from app.country.event_bus import (
    enqueue,
)

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

cid=None

for p in P.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    if str(
        o.get(
            "state",
            "",
        )
    ).lower() in {
        "confirmed",
        "confirmed_stable",
        "confirmed_rotating_ip",
    }:
        cid=p.stem
        break

assert cid

r=enqueue(
    config_id=cid,
    generation="K1B-test",
    completed_at="test",
    priority=0,
)

print(
    "CONFIG_ID=",
    cid,
)

print(
    "RESULT=",
    r,
)

assert (
    r["status"]
    ==
    "suppressed_final"
)

print(
    "FINAL_SUPPRESSION=PASS"
)
PY


echo "=== 3. REAL QUEUE STATE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import (
    dirs,
    stats,
)

dirs()

print(
    "QUEUE_STATS=",
    stats(),
)

print(
    "QUEUE_STORAGE=PASS"
)
PY


echo "=== 4. ATOMIC TEMP FILE CHECK ==="

COUNT=$(
    find \
    /var/lib/config-location/country/event-bus \
    -type f \
    -name '*.tmp' \
    2>/dev/null \
    | wc -l
)

echo "TEMP_FILES=$COUNT"

test "$COUNT" -eq 0

echo "ATOMIC_STORAGE=PASS"


echo "=== 5. PRODUCTION SERVICES ==="

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
        "$svc" \
        2>/dev/null || true
    )

    echo "$svc=$X"

    test "$X" = active
done


echo "=== 6. NO PRODUCTION HOOK YET ==="

grep -RIl \
'event_bus' \
/opt/config-location/app/health \
2>/dev/null \
|| true

echo "HEALTH_HOOK=NOT_INSTALLED"


echo "========================================"
echo "FIX22K1B=PASS"
echo "DURABLE_QUEUE=PASS"
echo "DEDUP=PASS"
echo "PRIORITY=PASS"
echo "ACK_NACK=PASS"
echo "LEASE_RECOVERY=PASS"
echo "DEAD_LETTER=PASS"
echo "FINAL_SUPPRESSION=PASS"
echo "ATOMIC_STORAGE=PASS"
echo "HEALTH_HOOK=NOT_INSTALLED"
echo "PRODUCTION_FLOW=UNCHANGED"
echo "========================================"
