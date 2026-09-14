#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

APP="$R/app/country/event_consumer.py"
UNIT=/etc/systemd/system/config-location-country-event-consumer.service

echo "=== 1. CURRENT CONSUMER CONTROLLER SOURCE ==="

grep -n \
-E \
'FIX22_CONSUMER_ADAPTIVE_CONTROLLER|def main|def worker_loop|target_workers|workers_live|pressure_decrease|backlog_increase|queue_low|Thread|STOP|COUNTRY_EVENT_CONSUMER_' \
"$APP" \
| head -n 800


echo
echo "=== 2. MAIN / WORKER SOURCE WINDOWS ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect

from app.country import event_consumer

for name in (
    "worker_loop",
    "main",
    "_cpu_percent_sample",
    "_memory_percent",
):

    fn=getattr(
        event_consumer,
        name,
        None,
    )

    if fn is None:
        continue

    print()
    print(
        "FUNCTION=",
        name,
    )

    print(
        "SIGNATURE=",
        inspect.signature(fn),
    )

    print(
        inspect.getsource(fn)
    )
PY


echo
echo "=== 3. SYSTEMD CONTRACT ==="

systemctl cat \
config-location-country-event-consumer.service \
--no-pager

echo

systemctl show \
config-location-country-event-consumer.service \
-p MainPID \
-p TasksCurrent \
-p TasksMax \
-p MemoryCurrent \
-p MemoryMax \
-p CPUQuotaPerSecUSec \
-p CPUWeight \
-p MemoryHigh \
-p MemoryMax \
-p OOMPolicy \
-p Restart \
-p RestartUSec \
--no-pager


echo
echo "=== 4. LIVE PROCESS / THREADS ==="

PID=$(
    systemctl show \
    config-location-country-event-consumer.service \
    -p MainPID \
    --value
)

echo "PID=$PID"

test "$PID" -gt 0

ps -p "$PID" \
-o pid,ppid,%cpu,%mem,rss,vsz,nlwp,etime,cmd

echo
echo "--- THREADS ---"

ps -T \
-p "$PID" \
-o pid,spid,pcpu,stat,etime,comm \
| head -n 100


echo
echo "=== 5. QUEUE PRESSURE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "QUEUE=",
    stats(),
)
PY


echo
echo "=== 6. LAST CONTROLLER DECISIONS ==="

"$PY" <<'PY'
from pathlib import Path
import json

p=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)

rows=[]

if p.exists():

    for line in p.read_text().splitlines():

        try:
            o=json.loads(line)
        except Exception:
            continue

        if o.get(
            "status"
        )=="controller":
            rows.append(o)


print(
    "CONTROLLER_ROWS_TOTAL=",
    len(rows),
)

for r in rows[-30:]:

    print(
        "CONTROL=",
        {
            "workers_live":
                r.get(
                    "workers_live"
                ),

            "workers_target":
                r.get(
                    "workers_target"
                ),

            "reason":
                r.get(
                    "reason"
                ),

            "pending":
                r.get(
                    "pending"
                ),

            "pending_delta":
                r.get(
                    "pending_delta"
                ),

            "cpu":
                r.get(
                    "cpu_percent"
                ),

            "memory":
                r.get(
                    "memory_percent"
                ),

            "error_rate":
                r.get(
                    "error_rate"
                ),

            "processed_window":
                r.get(
                    "processed_window"
                ),

            "acked_window":
                r.get(
                    "acked_window"
                ),
        },
    )
PY


echo
echo "=== 7. THREAD RETIREMENT CAPABILITY ==="

"$PY" <<'PY'
from pathlib import Path

p=Path(
    "/opt/config-location/app/country/"
    "event_consumer.py"
)

s=p.read_text()

checks={
    "per_worker_stop_event":
        (
            "worker_stop"
            in s
            or "retire_event"
            in s
            or "retire_worker"
            in s
        ),

    "thread_join":
        "join(" in s,

    "live_worker_registry":
        (
            "workers_live"
            in s
            or "threads"
            in s
        ),

    "target_worker_control":
        "target_workers" in s,

    "global_stop":
        "STOP" in s,
}

print(
    "RETIREMENT_CAPABILITIES=",
    checks,
)

if (
    checks[
        "target_worker_control"
    ]
    and not checks[
        "per_worker_stop_event"
    ]
):

    print(
        "REAL_SCALE_DOWN=NO"
    )

else:

    print(
        "REAL_SCALE_DOWN=MAYBE"
    )
PY


echo
echo "=== 8. SERVER CPU / MEMORY CAPACITY ==="

echo "--- CPU ---"

nproc

lscpu \
| grep -E \
'^(CPU\(s\)|Model name|Thread|Core|Socket|CPU max MHz|CPU min MHz)' \
|| true


echo
echo "--- MEMORY ---"

free -h

echo
echo "--- LOAD ---"

uptime


echo
echo "=== 9. TOP PROJECT RESOURCE USERS ==="

ps -eo \
pid,ppid,%cpu,%mem,rss,nlwp,etime,cmd \
--sort=-%cpu \
| grep -E \
'config-location|xray' \
| head -n 80 \
|| true


echo
echo "=== 10. EVENT CONSUMER ERROR PROFILE ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

p=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)

c=Counter()

if p.exists():

    for line in p.read_text().splitlines():

        try:
            o=json.loads(line)
        except Exception:
            continue

        c[
            str(
                o.get(
                    "status",
                    "unknown",
                )
            )
        ]+=1


print(
    "STATUS_COUNTS=",
    dict(c),
)

print(
    "ERRORS=",
    c.get("error",0),
)

print(
    "NACK_ERROR=",
    c.get(
        "nack_error",
        0,
    ),
)
PY


echo
echo "=== 11. SERVICE HEALTH ==="

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
echo "FIX22K8A=PASS"
echo "MODE=RESOURCE-CONTROLLER-BASELINE"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=FIX22K8B-REAL-WORKER-RETIREMENT"
echo "======================================================"
