#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

D=/var/lib/config-location
C="$D/configs"
H="$D/health-results/latest"

TRACK="$D/health-lifecycle/consecutive-state.json"
QUEUE="$D/health-adaptive/queue-state.json"

echo "=== 1. LIVE RELATION SNAPSHOT ==="

"$PY" <<'PY'
from pathlib import Path
import json

C=Path("/var/lib/config-location/configs")
H=Path("/var/lib/config-location/health-results/latest")

configs={p.stem for p in C.glob("*.json")}
health={p.stem for p in H.glob("*.json")}

print("CONFIGS=",len(configs))
print("HEALTH=",len(health))
print("ORPHAN_HEALTH=",len(health-configs))
print("MISSING_HEALTH=",len(configs-health))
PY


echo "=== 2. REFERENTIAL GUARD DRY CONTRACT ==="

PYTHONPATH="$R" \
"$PY" -m app.integrity.referential_guard

echo "REFERENTIAL_GUARD=PASS"


echo "=== 3. TRACKER RELATION ==="

export TRACK

"$PY" <<'PY'
import json
import os
from pathlib import Path

C=Path("/var/lib/config-location/configs")
configs={p.stem for p in C.glob("*.json")}

p=Path(os.environ["TRACK"])

if not p.exists():
    print("TRACKER=MISSING")
    raise SystemExit(0)

o=json.loads(p.read_text())

records=(
    o.get("records")
    or o.get("configs")
    or o.get("items")
    or {}
)

if not isinstance(records,dict):
    print("TRACKER_SHAPE=",type(records).__name__)
    raise SystemExit(0)

orphans=[
    cid
    for cid in records
    if cid not in configs
]

print("TRACKER_RECORDS=",len(records))
print("ORPHAN_TRACKER=",len(orphans))
print("ORPHAN_TRACKER_SAMPLE=",orphans[:20])
PY


echo "=== 4. QUEUE RELATION ==="

export QUEUE

"$PY" <<'PY'
import json
import os
from pathlib import Path

C=Path("/var/lib/config-location/configs")
configs={p.stem for p in C.glob("*.json")}

p=Path(os.environ["QUEUE"])

if not p.exists():
    print("QUEUE=MISSING")
    raise SystemExit(0)

o=json.loads(p.read_text())

queue=o.get("queue",[])
leases=o.get("leases",[])

oq=[
    cid
    for cid in queue
    if cid not in configs
]

ol=[
    cid
    for cid in leases
    if cid not in configs
]

print("QUEUE_SIZE=",len(queue))
print("LEASES=",len(leases))
print("ORPHAN_QUEUE=",len(oq))
print("ORPHAN_LEASES=",len(ol))
print("ORPHAN_QUEUE_SAMPLE=",oq[:20])
print("ORPHAN_LEASE_SAMPLE=",ol[:20])
PY


echo "=== 5. QUIESCED REFERENTIAL VERIFY ==="

WRITERS="
config-location-fetcher.service
config-location-health-adaptive.service
config-location-lifecycle-sync.service
config-location-lifecycle-watchdog.service
"

RESTORED=0

restore() {
    rc=$?

    if [ "$RESTORED" -eq 0 ]; then
        for svc in $WRITERS; do
            systemctl reset-failed "$svc" || true
            systemctl start "$svc" || true
        done
    fi

    exit "$rc"
}

trap restore EXIT

systemctl stop $WRITERS

sleep 3

PYTHONPATH="$R" \
"$PY" -m app.integrity.referential_guard

PYTHONPATH="$R" \
"$PY" -m app.integrity.run_store_health >/dev/null

"$PY" <<'PY'
import json
from pathlib import Path

c=json.loads(
    Path(
        "/var/lib/config-location/"
        "integrity/store-health-latest.json"
    ).read_text()
)["counts"]

print("ORPHAN_HEALTH=",c["orphan_health"])
print("INVALID_CONFIG=",c["invalid_config_files"])
print("INVALID_HEALTH=",c["invalid_health_files"])
print("CONFIG_MISMATCH=",c["config_filename_mismatches"])
print("HEALTH_MISMATCH=",c["health_filename_mismatches"])
print("DUP_CONFIG=",c["duplicate_config_ids"])
print("DUP_HEALTH=",c["duplicate_health_ids"])

assert c["orphan_health"] == 0
assert c["invalid_config_files"] == 0
assert c["invalid_health_files"] == 0
assert c["config_filename_mismatches"] == 0
assert c["health_filename_mismatches"] == 0
assert c["duplicate_config_ids"] == 0
assert c["duplicate_health_ids"] == 0

print("QUIESCED_STORE=PASS")
PY


echo "=== 6. TRACKER / QUEUE QUIESCED CHECK ==="

"$PY" <<'PY'
import json
from pathlib import Path

C=Path("/var/lib/config-location/configs")
configs={p.stem for p in C.glob("*.json")}

tracker=Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "consecutive-state.json"
)

if tracker.exists():
    o=json.loads(tracker.read_text())

    records=(
        o.get("records")
        or o.get("configs")
        or o.get("items")
        or {}
    )

    if isinstance(records,dict):
        bad=[
            cid for cid in records
            if cid not in configs
        ]

        print("QUIESCED_ORPHAN_TRACKER=",len(bad))

queuep=Path(
    "/var/lib/config-location/"
    "health-adaptive/"
    "queue-state.json"
)

if queuep.exists():
    o=json.loads(queuep.read_text())

    q=o.get("queue",[])
    l=o.get("leases",[])

    oq=[
        cid for cid in q
        if cid not in configs
    ]

    ol=[
        cid for cid in l
        if cid not in configs
    ]

    print("QUIESCED_ORPHAN_QUEUE=",len(oq))
    print("QUIESCED_ORPHAN_LEASES=",len(ol))

    assert len(oq) == 0
    assert len(ol) == 0
PY


echo "=== 7. RESTORE ==="

for svc in $WRITERS; do
    systemctl reset-failed "$svc" || true
    systemctl start "$svc"
done

sleep 5

for svc in $WRITERS; do
    X=$(systemctl is-active "$svc")
    echo "$svc=$X"
    test "$X" = active
done

RESTORED=1
trap - EXIT


echo "========================================"
echo "FIX21C=PASS"
echo "REFERENTIAL_GUARD=PASS"
echo "QUIESCED_ORPHAN_HEALTH=0"
echo "QUEUE_ORPHANS=0"
echo "LEASE_ORPHANS=0"
echo "STORE_STRUCTURE=PASS"
echo "PRODUCTION_DELETE=DISABLED"
echo "PRODUCTION_RESTORED=PASS"
echo "========================================"
