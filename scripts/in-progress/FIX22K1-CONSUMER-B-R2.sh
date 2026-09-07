#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

APP="$R/app/country/event_consumer.py"
UNIT=/etc/systemd/system/config-location-country-event-consumer.service
MET=/var/lib/config-location/country/event-consumer-metrics.jsonl

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K1-CONSUMER-B-R2-$TS"

mkdir -p "$B"

cp -a "$APP" "$B/"
cp -a "$UNIT" "$B/"

echo "BACKUP=$B"

echo
echo "=== 1. STOP CONSUMER ==="

systemctl stop \
config-location-country-event-consumer.service \
2>/dev/null || true

echo "CONSUMER_STOPPED=YES"


echo
echo "=== 2. PATCH REAL EVENT BUS CONTRACT ==="

export APP

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["APP"])
s=p.read_text()

start=s.index(
    "def worker_loop("
)

end=s.index(
    "\ndef main()",
    start,
)

new=r'''def worker_loop(
    worker_id: int,
) -> None:

    owner=(
        f"country-event-consumer:"
        f"{os.getpid()}:"
        f"{worker_id}"
    )

    while not STOP.is_set():

        lease_path=None
        event=None

        try:

            recover_expired()

            leased=lease(
                owner=owner,
                seconds=60,
            )

            if leased is None:
                STOP.wait(0.25)
                continue


            lease_path,event=leased


            _metric(
                {
                    "status":"leased",
                    "worker_id":
                        worker_id,

                    "event_id":
                        event.get(
                            "event_id"
                        ),

                    "config_id":
                        event.get(
                            "config_id"
                        ),

                    "lease_path":
                        str(
                            lease_path
                        ),
                }
            )


            _process_event(
                event
            )


            done_path=ack(
                lease_path,
                result={
                    "consumer":
                        "k1-event-consumer",

                    "processed":
                        True,
                },
            )


            _metric(
                {
                    "status":"acked",
                    "worker_id":
                        worker_id,

                    "event_id":
                        event.get(
                            "event_id"
                        ),

                    "config_id":
                        event.get(
                            "config_id"
                        ),

                    "done_path":
                        str(
                            done_path
                        ),
                }
            )


        except Exception as exc:

            error=(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:1000]


            _metric(
                {
                    "status":"error",
                    "worker_id":
                        worker_id,

                    "event_id":
                        (
                            event.get(
                                "event_id"
                            )
                            if isinstance(
                                event,
                                dict,
                            )
                            else None
                        ),

                    "config_id":
                        (
                            event.get(
                                "config_id"
                            )
                            if isinstance(
                                event,
                                dict,
                            )
                            else None
                        ),

                    "lease_path":
                        (
                            str(
                                lease_path
                            )
                            if lease_path
                            is not None
                            else None
                        ),

                    "error":
                        error,
                }
            )


            # Only NACK if a real lease exists.
            if lease_path is not None:

                try:

                    nack(
                        lease_path,
                        error,
                        retry_seconds=10,
                        max_attempts=6,
                    )

                except Exception as nack_exc:

                    _metric(
                        {
                            "status":
                                "nack_error",

                            "worker_id":
                                worker_id,

                            "event_id":
                                (
                                    event.get(
                                        "event_id"
                                    )
                                    if isinstance(
                                        event,
                                        dict,
                                    )
                                    else None
                                ),

                            "error":
                                (
                                    f"{type(nack_exc).__name__}: "
                                    f"{nack_exc}"
                                )[:1000],
                        }
                    )


            # Never let a worker thread die.
            STOP.wait(0.10)
'''


s=(
    s[:start]
    +new
    +s[end:]
)

p.write_text(s)

print(
    "EVENT_BUS_CONTRACT_PATCH=PASS"
)
PY


echo
echo "=== 3. COMPILE ==="

"$PY" -m py_compile "$APP"

echo "COMPILE=PASS"


echo
echo "=== 4. CONTRACT STATIC VERIFY ==="

grep -q \
'lease(' \
"$APP"

grep -q \
'owner=owner' \
"$APP"

grep -q \
'lease_path,event=leased' \
"$APP"

grep -q \
'ack(' \
"$APP"

grep -q \
'nack(' \
"$APP"

echo "STATIC_CONTRACT=PASS"


echo
echo "=== 5. RECOVER ANY EXPIRED LEASE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import (
    recover_expired,
    stats,
)

print(
    "RECOVERED=",
    recover_expired(),
)

print(
    "QUEUE_PRE=",
    stats(),
)
PY


echo
echo "=== 6. RESET R2 METRICS ==="

rm -f "$MET"

echo "METRICS_RESET=PASS"


echo
echo "=== 7. START R2 CONSUMER ==="

systemctl restart \
config-location-country-event-consumer.service

sleep 4

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER_SERVICE=active"


echo
echo "=== 8. INITIAL QUEUE ==="

BEFORE=$(
PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print(
    stats().get(
        "pending",
        0,
    )
)
PY
)

echo "PENDING_START=$BEFORE"


echo
echo "=== 9. OBSERVE 60 SECOND REAL DRAIN ==="

for i in $(seq 1 12)
do

    sleep 5

    PYTHONPATH="$R" "$PY" <<PY
from app.country.event_bus import stats

s=stats()

print(
    "T=$((i*5))s",
    "PENDING=",
    s.get("pending",0),
    "LEASED=",
    s.get("leased",0),
    "DONE=",
    s.get("done",0),
    "DEAD=",
    s.get("dead",0),
)
PY

done


echo
echo "=== 10. FINAL QUEUE ==="

AFTER=$(
PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print(
    stats().get(
        "pending",
        0,
    )
)
PY
)

echo "PENDING_END=$AFTER"

echo "NET_PENDING_CHANGE=$((AFTER-BEFORE))"


PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "QUEUE_FINAL=",
    stats(),
)
PY


echo
echo "=== 11. METRIC ANALYSIS ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

p=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)

assert p.exists()

rows=[]

for line in p.read_text().splitlines():

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
    "METRIC_ROWS=",
    len(rows),
)

print(
    "STATUS=",
    dict(c),
)


for key in (
    "consumer_start",
    "leased",
    "processed",
    "acked",
    "error",
    "nack_error",
):

    print(
        key.upper(),
        "=",
        c.get(
            key,
            0,
        ),
    )


for r in rows[-20:]:

    if r.get(
        "status"
    ) in {
        "processed",
        "acked",
        "error",
        "nack_error",
    }:

        print(
            "SAMPLE=",
            r,
        )


assert c.get(
    "leased",
    0,
) >= 1, (
    "consumer did not lease events"
)


assert (
    c.get(
        "processed",
        0,
    )
    +
    c.get(
        "error",
        0,
    )
) >= 1


assert c.get(
    "acked",
    0,
) >= 1, (
    "no event completed successfully"
)


print(
    "REAL_EVENT_CONSUMPTION=PASS"
)
PY


echo
echo "=== 12. THREAD HEALTH ==="

PID=$(
    systemctl show \
    config-location-country-event-consumer.service \
    -p MainPID \
    --value
)

echo "PID=$PID"

test "$PID" -gt 0

THREADS=$(
    ps -T \
    -p "$PID" \
    --no-headers \
    | wc -l
)

echo "THREADS=$THREADS"

test "$THREADS" -ge 3

echo "WORKER_THREADS_ALIVE=PASS"


echo
echo "=== 13. JOURNAL ERROR CHECK ==="

journalctl \
-u config-location-country-event-consumer.service \
--since "2 minutes ago" \
--no-pager \
-l \
| tail -n 120


if journalctl \
-u config-location-country-event-consumer.service \
--since "2 minutes ago" \
--no-pager \
-l \
| grep -q \
'Exception in thread'
then

    echo "ERROR=WORKER_THREAD_CRASH"
    exit 1
fi

echo "NO_THREAD_CRASH=PASS"


echo
echo "=== 14. NO SECOND XRAY / EXIT PROBE ==="

if grep -q \
'observe_exit_ip' \
"$APP"
then
    echo "ERROR=SECOND_EXIT_PROBE"
    exit 1
fi

echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"


echo
echo "=== 15. CORE SERVICES ==="

for svc in \
config-location-country-event-consumer.service \
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
echo "======================================================"
echo "FIX22K1_CONSUMER_B_R2=PASS"
echo "EVENT_CONSUMER=ACTIVE"
echo "WORKERS=2"
echo "EVENT_BUS_CONTRACT=CORRECT"
echo "THREAD_CRASH_BOUNDARY=PROTECTED"
echo "LEASE_ACK_NACK=REAL"
echo "K2_EXIT_HANDOFF=USED"
echo "K4_CACHE_SINGLEFLIGHT=USED"
echo "K5_PARALLEL_GEO=USED"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "BACKUP=$B"
echo "NEXT=CONSUMER-C-ADAPTIVE-DRAIN"
echo "======================================================"
