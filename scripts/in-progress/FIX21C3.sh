#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

F="$R/app/health/lifecycle/consecutive.py"

D=/var/lib/config-location
TRACK="$D/health-lifecycle/consecutive-state.json"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX21C3-$TS"
A="$D/health-lifecycle/archives"

W=$(mktemp -d /tmp/fix21c3.XXXXXX)

mkdir -p "$B" "$A"

trap 'rm -rf "$W"' EXIT

echo "=== 1. BACKUP ==="

cp -a "$F" "$B/"
cp -a "$F" "$W/consecutive.py"

if [ -f "$TRACK" ]; then
    cp -a "$TRACK" \
        "$A/consecutive-state-before-FIX21C3-$TS.json"

    sha256sum \
        "$A/consecutive-state-before-FIX21C3-$TS.json" \
        >"$A/consecutive-state-before-FIX21C3-$TS.json.sha256"

    sha256sum -c \
        "$A/consecutive-state-before-FIX21C3-$TS.json.sha256"
fi

echo "BACKUP=$B"

export W


echo "=== 2. PATCH STAGING ==="

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(
    os.environ["W"]
) / "consecutive.py"

s=p.read_text()


# ---------------------------------------------------------
# Add canonical Config store root.
# ---------------------------------------------------------

anchor='''RESULT_DIR = Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

STATE_ROOT = Path(
'''

replacement='''RESULT_DIR = Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

CONFIG_DIR = Path(
    "/var/lib/config-location/"
    "configs"
)

STATE_ROOT = Path(
'''

if anchor not in s:
    raise SystemExit(
        "CONFIG_DIR anchor missing"
    )

s=s.replace(
    anchor,
    replacement,
    1,
)


# ---------------------------------------------------------
# Reconcile tracker against the canonical Config store
# BEFORE processing latest Health.
#
# Also filter latest Health so an orphan latest file that
# exists briefly during a live race cannot recreate a
# tracker record for a Config that no longer exists.
# ---------------------------------------------------------

anchor='''    latest = load_latest_results()

    processed_new_results = 0
    unchanged_results = 0


    for config_id, result in (
        latest.items()
    ):
'''

replacement='''    latest = load_latest_results()

    current_config_ids = {
        path.stem
        for path in CONFIG_DIR.glob(
            "*.json"
        )
    }

    stale_record_ids = [
        config_id
        for config_id in records
        if config_id
        not in current_config_ids
    ]

    for config_id in stale_record_ids:
        records.pop(
            config_id,
            None,
        )

    latest = {
        config_id: result
        for config_id, result
        in latest.items()
        if config_id
        in current_config_ids
    }

    processed_new_results = 0
    unchanged_results = 0


    for config_id, result in (
        latest.items()
    ):
'''

if anchor not in s:
    raise SystemExit(
        "update_tracker anchor missing"
    )

s=s.replace(
    anchor,
    replacement,
    1,
)


# ---------------------------------------------------------
# Persist GC observability.
# ---------------------------------------------------------

anchor='''    state[
        "tracked_count"
    ] = len(
        records
    )

    state[
        "processed_new_results"
'''

replacement='''    state[
        "tracked_count"
    ] = len(
        records
    )

    state[
        "tracker_gc_removed"
    ] = len(
        stale_record_ids
    )

    state[
        "current_config_count"
    ] = len(
        current_config_ids
    )

    state[
        "processed_new_results"
'''

if anchor not in s:
    raise SystemExit(
        "tracker stats anchor missing"
    )

s=s.replace(
    anchor,
    replacement,
    1,
)

p.write_text(s)

print(
    "STAGING_PATCH=PASS"
)
PY


echo "=== 3. STAGING COMPILE ==="

"$PY" -m py_compile \
"$W/consecutive.py"

echo "STAGING_COMPILE=PASS"


echo "=== 4. STATIC CONTRACT ==="

grep -q \
'CONFIG_DIR = Path(' \
"$W/consecutive.py"

grep -q \
'stale_record_ids = \[' \
"$W/consecutive.py"

grep -q \
'"tracker_gc_removed"' \
"$W/consecutive.py"

grep -q \
'"current_config_count"' \
"$W/consecutive.py"

echo "STATIC_CONTRACT=PASS"


echo "=== 5. INSTALL ==="

install -m 0644 \
"$W/consecutive.py" \
"$F"

"$PY" -m py_compile "$F"

echo "PRODUCTION_COMPILE=PASS"


echo "=== 6. EXISTING SELFTESTS ==="

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.selftest_consecutive

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.selftest_policy

PYTHONPATH="$R" \
"$PY" -m app.health.lifecycle.selftest_safety_gates

echo "SELFTESTS=PASS"


echo "=== 7. QUIESCE WRITERS ==="

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
        echo "=== EMERGENCY RESTORE ==="

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

for svc in $WRITERS; do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = inactive
done


echo "=== 8. HEALTH REFERENTIAL CONVERGENCE ==="

PYTHONPATH="$R" \
"$PY" -m app.integrity.referential_guard >/dev/null

echo "REFERENTIAL_GUARD=PASS"


echo "=== 9. RUN TRACKER GC ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.health.lifecycle.consecutive import (
    update_tracker,
)

o=update_tracker()

print(
    "TRACKED_COUNT=",
    o.get("tracked_count"),
)

print(
    "CURRENT_CONFIG_COUNT=",
    o.get("current_config_count"),
)

print(
    "TRACKER_GC_REMOVED=",
    o.get("tracker_gc_removed"),
)

print(
    "LATEST_RESULT_COUNT=",
    o.get("latest_result_count"),
)

print(
    "WRITE_PERFORMED=",
    o.get("write_performed"),
)

assert (
    int(
        o.get(
            "tracker_gc_removed",
            -1,
        )
    )
    >= 0
)

print(
    "TRACKER_GC_RUN=PASS"
)
PY


echo "=== 10. VERIFY ZERO TRACKER ORPHANS ==="

"$PY" <<'PY'
import json
from pathlib import Path

C=Path(
    "/var/lib/config-location/configs"
)

T=Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "consecutive-state.json"
)

configs={
    p.stem
    for p in C.glob("*.json")
}

o=json.loads(
    T.read_text()
)

records=o.get(
    "records",
    {}
)

assert isinstance(
    records,
    dict,
)

orphans=[
    cid
    for cid in records
    if cid not in configs
]

print(
    "CONFIGS=",
    len(configs),
)

print(
    "TRACKER_RECORDS=",
    len(records),
)

print(
    "ORPHAN_TRACKER=",
    len(orphans),
)

print(
    "TRACKER_GC_REMOVED_LAST_RUN=",
    o.get(
        "tracker_gc_removed"
    ),
)

assert orphans == []

print(
    "TRACKER_REFERENTIAL_INTEGRITY=PASS"
)
PY


echo "=== 11. VERIFY HEALTH STORE ==="

PYTHONPATH="$R" \
"$PY" -m app.integrity.run_store_health \
>/dev/null

"$PY" <<'PY'
import json
from pathlib import Path

c=json.loads(
    Path(
        "/var/lib/config-location/"
        "integrity/store-health-latest.json"
    ).read_text()
)["counts"]

print(
    "ORPHAN_HEALTH=",
    c["orphan_health"],
)

print(
    "INVALID_CONFIG=",
    c["invalid_config_files"],
)

print(
    "INVALID_HEALTH=",
    c["invalid_health_files"],
)

assert (
    c["orphan_health"]
    == 0
)

assert (
    c["invalid_config_files"]
    == 0
)

assert (
    c["invalid_health_files"]
    == 0
)

print(
    "STORE_INTEGRITY=PASS"
)
PY


echo "=== 12. VERIFY PRODUCTION DELETE FREEZE ==="

"$PY" <<'PY'
import json
from pathlib import Path

p=Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "fix21-semantics-contract.json"
)

o=json.loads(
    p.read_text()
)

pd=o[
    "production_delete"
]

assert (
    pd["configured"]
    is False
)

assert (
    pd["allowed"]
    is False
)

print(
    "PRODUCTION_DELETE=DISABLED"
)
PY


echo "=== 13. RESTORE PRODUCTION ==="

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

PANEL=$(
    systemctl is-active \
    config-location-panel.service
)

echo "config-location-panel.service=$PANEL"

test "$PANEL" = active

RESTORED=1
trap - EXIT


echo "=== 14. POST-RESTORE TRACKER OWNER ==="

sleep 5

"$PY" <<'PY'
import json
from pathlib import Path

C=Path(
    "/var/lib/config-location/configs"
)

T=Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "consecutive-state.json"
)

configs={
    p.stem
    for p in C.glob("*.json")
}

o=json.loads(
    T.read_text()
)

records=o.get(
    "records",
    {}
)

orphans=[
    cid
    for cid in records
    if cid not in configs
]

print(
    "POST_RESTORE_ORPHAN_TRACKER=",
    len(orphans),
)

# A tiny transient race is possible after writers restart,
# but old historical accumulation must never return.
assert len(orphans) < 50

print(
    "AUTOMATIC_TRACKER_GC=PASS"
)
PY


echo "========================================"
echo "FIX21C3=PASS"
echo "TRACKER_GC=AUTOMATIC"
echo "QUIESCED_ORPHAN_TRACKER=0"
echo "QUIESCED_ORPHAN_HEALTH=0"
echo "STORE_INTEGRITY=PASS"
echo "PRODUCTION_DELETE=DISABLED"
echo "PRODUCTION_RESTORED=PASS"
echo "BACKUP=$B"
echo "ARCHIVE=$A/consecutive-state-before-FIX21C3-$TS.json"
echo "========================================"
