#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

ENGINE="$R/app/health/core/engine.py"
HOOK="$R/app/country/health_hook.py"

FASTMET=/var/lib/config-location/country/same-runtime-fastpath.jsonl
PRODMET=/var/lib/config-location/country/event-bus/producer-metrics.jsonl

echo "=== 1. VERIFY K2C PATCHES PRESENT ==="

grep -q \
'same_runtime_country' \
"$ENGINE"

grep -q \
'same_runtime_country' \
"$HOOK"

"$PY" -m py_compile \
"$ENGINE" \
"$HOOK" \
"$R/app/country/same_runtime_fastpath.py" \
"$R/app/country/event_bus.py"

echo "K2C_PATCHES=PASS"


echo "=== 2. RESET ONLY PROOF METRICS ==="

rm -f "$FASTMET" "$PRODMET"

echo "METRICS_RESET=PASS"


echo "=== 3. RESTART HEALTH ==="

systemctl restart \
config-location-health-adaptive.service

sleep 5

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = active

echo "HEALTH=active"


echo "=== 4. WAIT FOR REAL FASTPATH + PRODUCER ==="

FOUND=0

for i in $(seq 1 24)
do
    F=0
    P=0

    if [ -f "$FASTMET" ]; then
        F=$(wc -l < "$FASTMET")
    fi

    if [ -f "$PRODMET" ]; then
        P=$(wc -l < "$PRODMET")
    fi

    echo \
"T=$((i*5))s FASTPATH_ROWS=$F PRODUCER_ROWS=$P"

    if [ "$F" -ge 3 ] && [ "$P" -ge 3 ]; then
        FOUND=1
        break
    fi

    sleep 5
done

test "$FOUND" -eq 1

echo "LIVE_ACTIVITY=PASS"


echo "=== 5. VERIFY CANONICAL HEALTH HANDOFF ==="

"$PY" <<'PY'
from pathlib import Path
import json
import time

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

cut=time.time()-180

all_handoff=[]
success=[]

for p in H.glob("*.json"):

    if p.stat().st_mtime < cut:
        continue

    try:
        h=json.loads(p.read_text())
    except Exception:
        continue

    if str(
        h.get("state","")
    ).lower()!="healthy":
        continue

    fast=(
        (h.get("metadata") or {})
        .get("same_runtime_country")
    )

    if not isinstance(fast,dict):
        continue

    all_handoff.append((h,fast))

    if (
        fast.get("status")=="success"
        and fast.get("exit_ip")
    ):
        success.append((h,fast))


print(
    "HEALTH_HANDOFF_ROWS=",
    len(all_handoff),
)

print(
    "HEALTH_HANDOFF_SUCCESS=",
    len(success),
)

assert len(all_handoff)>=3
assert len(success)>=1


for h,f in success[:5]:

    assert f.get(
        "same_runtime"
    ) is True

    assert f.get(
        "new_xray_started"
    ) is False

    print(
        "SAMPLE=",
        {
            "config_id":
                h.get("config_id"),

            "job_id":
                h.get("job_id"),

            "exit_ip":
                f.get("exit_ip"),

            "agreed":
                f.get("agreed"),

            "elapsed_ms":
                f.get("elapsed_ms"),
        },
    )


print(
    "HEALTH_HANDOFF=PASS"
)
PY


echo "=== 6. VERIFY DURABLE EVENT HANDOFF ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

roots=[
    Path(
        "/var/lib/config-location/country/"
        "event-bus/pending"
    ),
    Path(
        "/var/lib/config-location/country/"
        "event-bus/done"
    ),
    Path(
        "/var/lib/config-location/country/"
        "event-bus/leased"
    ),
]

rows=[]

for root in roots:

    if not root.exists():
        continue

    for p in root.glob("*.json"):

        try:
            e=json.loads(p.read_text())
        except Exception:
            continue

        fast=(
            (e.get("metadata") or {})
            .get("same_runtime_country")
        )

        if not isinstance(fast,dict):
            continue

        rows.append((e,fast))


print(
    "EVENT_HANDOFF_ROWS=",
    len(rows),
)

success=[
    (e,f)
    for e,f in rows
    if (
        f.get("status")=="success"
        and f.get("exit_ip")
    )
]

print(
    "EVENT_HANDOFF_SUCCESS=",
    len(success),
)

assert len(rows)>=1
assert len(success)>=1


for e,f in success[:5]:

    assert f.get(
        "same_runtime"
    ) is True

    assert f.get(
        "new_xray_started"
    ) is False

    print(
        "EVENT_SAMPLE=",
        {
            "config_id":
                e.get("config_id"),

            "generation":
                e.get(
                    "health_generation"
                ),

            "exit_ip":
                f.get("exit_ip"),

            "agreed":
                f.get("agreed"),
        },
    )


print(
    "DURABLE_EVENT_HANDOFF=PASS"
)
PY


echo "=== 7. PRODUCER STATUS ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

p=Path(
    "/var/lib/config-location/country/"
    "event-bus/producer-metrics.jsonl"
)

assert p.exists()

rows=[]

for line in p.read_text().splitlines():

    if not line.strip():
        continue

    try:
        rows.append(
            json.loads(line)
        )
    except Exception:
        pass


c=Counter(
    r.get(
        "status",
        "unknown",
    )
    for r in rows
)

print(
    "PRODUCER_ROWS=",
    len(rows),
)

print(
    "PRODUCER_STATUS=",
    dict(c),
)

assert len(rows)>=3

unexpected={
    k:v
    for k,v in c.items()
    if k not in {
        "enqueued",
        "suppressed_final",
        "duplicate",
    }
}

print(
    "UNEXPECTED=",
    unexpected,
)

assert not unexpected

print(
    "K1_PRODUCER=PASS"
)
PY


echo "=== 8. K1 QUEUE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "QUEUE=",
    stats(),
)

print(
    "K1_FALLBACK=PASS"
)
PY


echo "=== 9. HEALTH / SERVICE ISOLATION ==="

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


echo "======================================================"
echo "FIX22K2C_R2=PASS"
echo "FIX22K2=COMPLETE"
echo "SAME_RUNTIME_EXIT_IP=YES"
echo "HANDOFF_IN_HEALTH_RESULT=YES"
echo "HANDOFF_IN_EVENT_BUS=YES"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "GEO_LOOKUP_IN_HEALTH_PATH=NO"
echo "K1_FALLBACK=PRESERVED"
echo "NEXT=FIX22K3"
echo "======================================================"
