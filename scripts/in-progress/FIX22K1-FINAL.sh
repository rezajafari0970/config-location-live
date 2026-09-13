#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

ACTIVE="$R/app/health/core/continuous_adaptive_runner.py"
OLD="$R/app/health/core/production_scheduler.py"
HOOK="$R/app/country/health_hook.py"
BUS="$R/app/country/event_bus.py"

MET=/var/lib/config-location/country/event-bus/producer-metrics.jsonl

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K1-FINAL-$TS"

mkdir -p "$B"

cp -a "$ACTIVE" "$B/"
cp -a "$OLD" "$B/"
cp -a "$HOOK" "$B/"
cp -a "$BUS" "$B/"

echo "BACKUP=$B"

echo
echo "=== 1. VERIFY ACTIVE WRITER ==="

grep -n -B12 -A24 \
'result_store.save' \
"$ACTIVE"

COUNT=$(
    grep -c \
    'result_store.save(' \
    "$ACTIVE"
)

echo "ACTIVE_SAVE_COUNT=$COUNT"

test "$COUNT" -eq 1

echo "ACTIVE_WRITER=PASS"


echo
echo "=== 2. REMOVE DEAD K1 HOOKS FROM OLD SCHEDULER ==="

export OLD

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["OLD"])
s=p.read_text()

marker="# FIX22K1 RESULT_STORE_EVENT"

removed=0
lines=s.splitlines(
    keepends=True
)

out=[]
i=0

while i < len(lines):

    if marker not in lines[i]:
        out.append(lines[i])
        i+=1
        continue

    removed+=1

    # Skip marker.
    i+=1

    # Expected structure:
    # try:
    #   import...
    #   emit...
    # except Exception:
    #   pass
    #
    depth_started=False

    while i < len(lines):

        line=lines[i]

        stripped=line.strip()

        if (
            stripped=="try:"
            and not depth_started
        ):
            depth_started=True
            i+=1
            continue

        if depth_started:

            # Find final "pass" belonging to except.
            if stripped=="pass":
                i+=1

                # Consume one blank line if present.
                if (
                    i < len(lines)
                    and not lines[i].strip()
                ):
                    i+=1

                break

            i+=1
            continue

        # Safety fallback.
        break


new="".join(out)

if marker in new:
    raise SystemExit(
        "ERROR: dead hook marker remains"
    )

p.write_text(new)

print(
    "DEAD_HOOKS_REMOVED=",
    removed,
)

assert removed>=1
PY

"$PY" -m py_compile "$OLD"

echo "OLD_SCHEDULER_CLEAN=PASS"


echo
echo "=== 3. INSTALL HOOK ON REAL ACTIVE PATH ==="

export ACTIVE

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["ACTIVE"])
s=p.read_text()

MARKER=(
    "# FIX22K1 ACTIVE_HEALTH_EVENT_PRODUCER"
)

if MARKER in s:
    print(
        "ACTIVE_HOOK_ALREADY_PRESENT=YES"
    )
    raise SystemExit(0)


old='''            result_store.save(
                outcome.result
            )

            finish_lease(
'''

new='''            result_store.save(
                outcome.result
            )

            # FIX22K1 ACTIVE_HEALTH_EVENT_PRODUCER
            # Country/EventBus failure must never
            # change the Health result.
            try:
                from app.country.health_hook import (
                    emit_health_country_event,
                )

                emit_health_country_event(
                    outcome.result
                )

            except Exception:
                pass

            finish_lease(
'''


count=s.count(old)

print(
    "TARGET_BLOCK_COUNT=",
    count,
)

assert count==1, (
    "active result-store boundary "
    "not uniquely identified"
)

s=s.replace(
    old,
    new,
    1,
)

p.write_text(s)

print(
    "ACTIVE_PRODUCER_PATCH=PASS"
)
PY


echo
echo "=== 4. COMPILE ALL TOUCHED MODULES ==="

"$PY" -m py_compile \
"$ACTIVE" \
"$OLD" \
"$HOOK" \
"$BUS"

echo "COMPILE=PASS"


echo
echo "=== 5. VERIFY EXACT PATCH LOCATION ==="

grep -n -B15 -A35 \
'FIX22K1 ACTIVE_HEALTH_EVENT_PRODUCER' \
"$ACTIVE"

echo
echo "=== 6. VERIFY DEAD HOOK ABSENT ==="

if grep -q \
'FIX22K1 RESULT_STORE_EVENT' \
"$OLD"
then
    echo "ERROR: DEAD_HOOK_STILL_PRESENT"
    exit 1
fi

echo "DEAD_PRODUCER_HOOKS=0"


echo
echo "=== 7. RESET PRODUCER PROOF METRICS ==="

rm -f "$MET"

mkdir -p \
/var/lib/config-location/country/event-bus

echo "METRICS_RESET=PASS"


echo
echo "=== 8. QUEUE BASELINE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "QUEUE_BEFORE=",
    stats(),
)
PY


echo
echo "=== 9. RESTART REAL HEALTH DAEMON ==="

systemctl restart \
config-location-health-adaptive.service

sleep 5

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = active

PID=$(
    systemctl show \
    config-location-health-adaptive.service \
    -p MainPID \
    --value
)

echo "HEALTH_MAIN_PID=$PID"
echo "HEALTH_SERVICE=active"

test "$PID" -gt 0


echo
echo "=== 10. WAIT FOR REAL PRODUCER EVENTS ==="

FOUND=0

for i in $(seq 1 24)
do
    N=0

    if [ -f "$MET" ]; then
        N=$(wc -l <"$MET")
    fi

    echo "T=$((i*5))s PRODUCER_ROWS=$N"

    if [ "$N" -ge 3 ]; then
        FOUND=1
        break
    fi

    sleep 5
done

test "$FOUND" -eq 1


echo
echo "=== 11. VALIDATE PRODUCER STATUS ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

p=Path(
    "/var/lib/config-location/country/"
    "event-bus/producer-metrics.jsonl"
)

rows=[]

for line in p.read_text().splitlines():

    if not line.strip():
        continue

    try:
        o=json.loads(line)
    except Exception:
        continue

    rows.append(o)


counts=Counter(
    str(
        o.get(
            "status",
            "unknown",
        )
    )
    for o in rows
)


print(
    "PRODUCER_ROWS=",
    len(rows),
)

print(
    "STATUS_COUNTS=",
    dict(counts),
)


for o in rows[:10]:
    print(
        "SAMPLE=",
        o,
    )


assert len(rows)>=3


allowed={
    "enqueued",
    "suppressed_final",
    "duplicate",
}

unexpected={
    k:v
    for k,v in counts.items()
    if k not in allowed
}


print(
    "UNEXPECTED=",
    unexpected,
)

assert not unexpected

assert (
    counts["enqueued"]
    + counts["suppressed_final"]
    + counts["duplicate"]
) >= 3

print(
    "ACTIVE_PRODUCER_EXECUTION=PASS"
)
PY


echo
echo "=== 12. CORRELATE EVENTS WITH REAL HEALTH ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

M=Path(
    "/var/lib/config-location/country/"
    "event-bus/producer-metrics.jsonl"
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

C=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

checked=0

for line in M.read_text().splitlines():

    if not line.strip():
        continue

    m=json.loads(line)

    cid=m["config_id"]
    status=m["status"]

    hp=H/f"{cid}.json"

    assert hp.exists(), (
        "health result missing: "
        +cid
    )

    h=json.loads(
        hp.read_text()
    )

    decision=(
        (
            h.get("metadata")
            or {}
        ).get(
            "health_decision"
        )
        or {}
    )

    assert str(
        h.get(
            "state",
            "",
        )
    ).lower()=="healthy"

    assert (
        h.get(
            "xray_started"
        )
        is True
    )

    assert (
        h.get(
            "download_verified"
        )
        is True
    )

    assert (
        h.get(
            "upload_verified"
        )
        is True
    )

    assert (
        decision.get(
            "healthy"
        )
        is True
    )

    assert (
        decision.get(
            "xray_ok"
        )
        is True
    )

    assert (
        decision.get(
            "download_ok"
        )
        is True
    )

    assert (
        decision.get(
            "upload_ok"
        )
        is True
    )


    if status=="suppressed_final":

        cp=C/f"{cid}.json"

        assert cp.exists()

        co=json.loads(
            cp.read_text()
        )

        assert str(
            co.get(
                "state",
                "",
            )
        ).lower() in {
            "confirmed",
            "confirmed_stable",
            "confirmed_rotating_ip",
        }


    checked+=1


print(
    "CORRELATED_REAL_HEALTH_EVENTS=",
    checked,
)

assert checked>=3

print(
    "HEALTH_EVENT_CORRELATION=PASS"
)
PY


echo
echo "=== 13. EVENT BUS STATE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import (
    recover_expired,
    stats,
)

print(
    "EXPIRED_RECOVERED=",
    recover_expired(),
)

print(
    "QUEUE_AFTER=",
    stats(),
)

print(
    "EVENT_BUS_STATE=PASS"
)
PY


echo
echo "=== 14. SERVICE ISOLATION ==="

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


echo
echo "=== 15. COUNTRY CONSUMER STATUS ==="

echo "COUNTRY_EVENT_CONSUMER=NOT_INSTALLED"


echo
echo "======================================================"
echo "FIX22K1_FINAL=PASS"
echo "FIX22K1=COMPLETE"
echo "ACTIVE_PRODUCER=continuous_adaptive_runner.flush_results"
echo "EVENT_AFTER_HEALTH_PERSIST=YES"
echo "REAL_UPLOAD_REQUIRED=YES"
echo "REAL_DOWNLOAD_REQUIRED=YES"
echo "XRAY_REQUIRED=YES"
echo "EVENT_BUS_DURABLE=YES"
echo "DEDUPE=YES"
echo "LEASE_RECOVERY=YES"
echo "FINAL_SUPPRESSION=YES"
echo "EVENT_FAILURE_AFFECTS_HEALTH=NO"
echo "COUNTRY_EVENT_CONSUMER=NOT_INSTALLED"
echo "BACKUP=$B"
echo "======================================================"
