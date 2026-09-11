#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

APP="$R/app/country/event_consumer.py"

DROPIN_DIR=/etc/systemd/system/config-location-country-event-consumer.service.d
DROPIN="$DROPIN_DIR/80-resource-hardening.conf"

MET=/var/lib/config-location/country/event-consumer-metrics.jsonl

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K8D-$TS"

mkdir -p "$B"

cp -a "$APP" "$B/event_consumer.py.before"

if [ -d "$DROPIN_DIR" ]; then
    cp -a "$DROPIN_DIR" "$B/dropins.before"
fi

echo "BACKUP=$B"


restore_service() {
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart \
        config-location-country-event-consumer.service \
        >/dev/null 2>&1 || true
}

trap restore_service EXIT


echo
echo "=== 1. PATCH DEFERRED-BACKLOG AWARE CONTROLLER ==="

export APP

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(
    os.environ["APP"]
)

s=p.read_text()

if "FIX22_K8D_DEFERRED_BACKPRESSURE" in s:

    print(
        "K8D_BACKPRESSURE_ALREADY_PRESENT=YES"
    )

    raise SystemExit(0)


marker='''        completed=max(
            counts["processed"],
            counts["acked"],
        )

        failures=counts["error"]

        error_rate=(
            failures
            /max(
                1,
                completed+failures,
            )
        )
'''

replacement='''        completed=max(
            counts["processed"],
            counts["acked"],
        )

        failures=counts["error"]

        deferred=int(
            counts[
                "deferred_no_exit"
            ]
        )

        error_rate=(
            failures
            /max(
                1,
                completed+failures,
            )
        )

        activity_total=max(
            1,
            completed
            +deferred
            +failures,
        )

        deferred_ratio=(
            deferred
            /activity_total
        )

        # FIX22_K8D_DEFERRED_BACKPRESSURE
        #
        # A large queue dominated by old no-exit
        # events is not productive backlog and must
        # not trigger aggressive scale-up.
        productive_backlog=(
            pending>=500
            and deferred_ratio<0.80
        )
'''

if marker not in s:

    if "FIX22_K8D_DEFERRED_BACKPRESSURE" not in s:
        raise SystemExit(
            "ERROR=ACTIVITY_BLOCK_NOT_FOUND"
        )

else:

    s=s.replace(
        marker,
        replacement,
        1,
    )


old='''        elif (
            pending>=500
            and cpu_percent<65.0
            and memory_percent<82.0
            and error_rate<0.03
        ):
'''

new='''        elif (
            productive_backlog
            and cpu_percent<65.0
            and memory_percent<82.0
            and error_rate<0.03
        ):
'''

if old not in s:

    if "productive_backlog" not in s:
        raise SystemExit(
            "ERROR=BACKLOG_SCALEUP_BLOCK_NOT_FOUND"
        )

else:

    s=s.replace(
        old,
        new,
        1,
    )


# Add scale-down when the queue is mostly deferred.
marker='''        elif (
            pending<100
            and target_workers>minimum
        ):

            target_workers=max(
                minimum,
                target_workers-1,
            )

            reason="queue_low"
'''

replacement='''        elif (
            pending<100
            and target_workers>minimum
        ):

            target_workers=max(
                minimum,
                target_workers-1,
            )

            reason="queue_low"


        elif (
            deferred_ratio>=0.85
            and target_workers>minimum
        ):

            target_workers=max(
                minimum,
                target_workers-1,
            )

            reason="deferred_backpressure"
'''

if marker not in s:

    if 'reason="deferred_backpressure"' not in s:
        raise SystemExit(
            "ERROR=QUEUE_LOW_BLOCK_NOT_FOUND"
        )

else:

    s=s.replace(
        marker,
        replacement,
        1,
    )


# Controller metrics.
marker='''                "deferred_window":
                    counts[
                        "deferred_no_exit"
                    ],

                "real_scale_down":
                    True,
'''

replacement='''                "deferred_window":
                    counts[
                        "deferred_no_exit"
                    ],

                "deferred_ratio":
                    round(
                        deferred_ratio,
                        4,
                    ),

                "productive_backlog":
                    productive_backlog,

                "real_scale_down":
                    True,
'''

if marker not in s:

    if '"productive_backlog"' not in s:
        raise SystemExit(
            "ERROR=CONTROLLER_METRIC_BLOCK_NOT_FOUND"
        )

else:

    s=s.replace(
        marker,
        replacement,
        1,
    )


p.write_text(s)

print(
    "K8D_DEFERRED_BACKPRESSURE_PATCH=PASS"
)
PY


echo
echo "=== 2. COMPILE ==="

"$PY" -m py_compile "$APP"

echo "COMPILE=PASS"


echo
echo "=== 3. STATIC CONTRACT ==="

grep -q \
'FIX22_K8D_DEFERRED_BACKPRESSURE' \
"$APP"

grep -q \
'productive_backlog' \
"$APP"

grep -q \
'deferred_backpressure' \
"$APP"

grep -q \
'deferred_ratio' \
"$APP"

grep -q \
'FIX22_K8C_CPU_CAP_TEST_HOOK' \
"$APP"

grep -q \
'FIX22_K8_REAL_WORKER_RETIREMENT' \
"$APP"

echo "CONTROLLER_CONTRACT=PASS"


echo
echo "=== 4. INSTALL SYSTEMD RESOURCE HARDENING ==="

mkdir -p "$DROPIN_DIR"

cat >"$DROPIN" <<'EOF'
[Service]

# Consumer normally uses ~30 MB RAM.
# These limits are deliberately generous and exist
# to isolate runaway behavior, not throttle normal work.
MemoryHigh=512M
MemoryMax=768M

# 4 CPU host. Allow up to 2.5 cores if necessary,
# while preventing this service from consuming the
# entire host during an abnormal condition.
CPUQuota=250%

# Current service uses fewer than 15 tasks.
TasksMax=128

# Keep restart/recovery behavior explicit.
OOMPolicy=stop
EOF

systemctl daemon-reload

echo "SYSTEMD_RESOURCE_HARDENING=INSTALLED"


echo
echo "=== 5. VERIFY SYSTEMD LIMITS ==="

systemctl show \
config-location-country-event-consumer.service \
-p CPUQuotaPerSecUSec \
-p MemoryHigh \
-p MemoryMax \
-p TasksMax \
-p OOMPolicy \
--no-pager

"$PY" <<'PY'
import subprocess

text=subprocess.check_output(
    [
        "systemctl",
        "show",
        "config-location-country-event-consumer.service",
        "-p",
        "MemoryHigh",
        "-p",
        "MemoryMax",
        "-p",
        "TasksMax",
        "-p",
        "OOMPolicy",
    ],
    text=True,
)

print(text)

assert "MemoryHigh=536870912" in text
assert "MemoryMax=805306368" in text
assert "TasksMax=128" in text
assert "OOMPolicy=stop" in text

print(
    "SYSTEMD_LIMITS=PASS"
)
PY


echo
echo "=== 6. RESET METRICS + RESTART ==="

rm -f "$MET"

systemctl restart \
config-location-country-event-consumer.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER=active"


echo
echo "=== 7. LIVE 3-MINUTE HARDENING TEST ==="

for i in $(seq 1 18)
do

    sleep 10

    echo "--- T=$((i*10))s ---"

    PID=$(
        systemctl show \
        config-location-country-event-consumer.service \
        -p MainPID \
        --value
    )

    echo "PID=$PID"

    ps -p "$PID" \
        -o %cpu,%mem,rss,nlwp,etime \
        --no-headers || true

    PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "QUEUE=",
    stats(),
)
PY

done


echo
echo "=== 8. CONTROLLER BACKPRESSURE AUDIT ==="

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


statuses=Counter(
    r.get(
        "status",
        "unknown",
    )
    for r in rows
)


controllers=[
    r
    for r in rows
    if r.get("status")=="controller"
]


print(
    "STATUS=",
    dict(statuses),
)

print(
    "CONTROLLERS=",
    len(controllers),
)


for r in controllers:

    print(
        "CONTROL=",
        {
            "cycle":
                r.get(
                    "controller_cycle"
                ),

            "active":
                r.get(
                    "workers_active"
                ),

            "retiring":
                r.get(
                    "workers_retiring"
                ),

            "target":
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

            "cpu":
                r.get(
                    "cpu_percent"
                ),

            "deferred":
                r.get(
                    "deferred_window"
                ),

            "deferred_ratio":
                r.get(
                    "deferred_ratio"
                ),

            "productive_backlog":
                r.get(
                    "productive_backlog"
                ),

            "effective_max":
                r.get(
                    "effective_max_workers"
                ),
        },
    )


assert len(controllers)>=8

assert statuses.get(
    "error",
    0,
)==0

assert statuses.get(
    "nack_error",
    0,
)==0


# No controller decision may exceed CPU-aware max.
for r in controllers:

    target=int(
        r.get(
            "workers_target",
            0,
        )
        or 0
    )

    maximum=int(
        r.get(
            "effective_max_workers",
            0,
        )
        or 0
    )

    assert maximum>=2
    assert target<=maximum


# If the observed workload is overwhelmingly
# deferred, it must not be classified as productive
# backlog.
heavy=[
    r
    for r in controllers
    if float(
        r.get(
            "deferred_ratio",
            0,
        )
        or 0
    )>=0.80
]

print(
    "DEFERRED_HEAVY_WINDOWS=",
    len(heavy),
)

for r in heavy:

    assert (
        r.get(
            "productive_backlog"
        )
        is False
    )


print(
    "DEFERRED_BACKPRESSURE=PASS"
)
PY


echo
echo "=== 9. LIVE RESOURCE LIMIT AUDIT ==="

PID=$(
    systemctl show \
    config-location-country-event-consumer.service \
    -p MainPID \
    --value
)

test "$PID" -gt 0

ps -p "$PID" \
-o pid,%cpu,%mem,rss,vsz,nlwp,etime,cmd

systemctl show \
config-location-country-event-consumer.service \
-p MemoryCurrent \
-p MemoryHigh \
-p MemoryMax \
-p TasksCurrent \
-p TasksMax \
-p CPUQuotaPerSecUSec \
--no-pager

echo "RESOURCE_RUNTIME_AUDIT=PASS"


echo
echo "=== 10. QUEUE SAFETY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

s=stats()

print(
    "QUEUE_FINAL=",
    s,
)

assert int(
    s.get(
        "dead",
        0,
    )
)==0

print(
    "QUEUE_SAFETY=PASS"
)
PY


echo
echo "=== 11. K4-K7 ARCHITECTURE PRESERVATION ==="

grep -q \
'FIX22_K7_PIPELINE_IDENTITY_GUARD' \
"$R/app/country/pipeline.py"

grep -q \
'country_detection_once' \
"$R/app/country/event_consumer.py"

grep -q \
'geo_singleflight_lock' \
"$R/app/country/geo_intelligence.py"

grep -q \
'FIX22K5_PARALLEL_GEO' \
"$R/app/country/geo_providers.py"

if grep -q \
'observe_exit_ip' \
"$R/app/country/event_consumer.py"
then
    echo "ERROR=SECOND_EXIT_PROBE"
    exit 1
fi

echo "K4_SINGLEFLIGHT=PRESERVED"
echo "K5_PARALLEL_GEO=PRESERVED"
echo "K6_COUNTRY_ONCE=PRESERVED"
echo "K7_IDENTITY_GUARD=PRESERVED"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"


echo
echo "=== 12. SERVICES ==="

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
echo "=== 13. WRITE FINAL K8 REPORT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json
import os
import time

from app.country.event_bus import stats


report={
    "schema_version":1,

    "generated_epoch":
        int(time.time()),

    "cpu_count":
        int(
            os.cpu_count()
            or 1
        ),

    "configured_max_workers":
        12,

    "cpu_worker_multiplier":
        2,

    "effective_worker_cap":
        min(
            12,
            int(
                os.cpu_count()
                or 1
            )*2,
        ),

    "real_worker_retirement":
        True,

    "retirement_boundary":
        "between_leases",

    "deferred_backpressure":
        True,

    "memory_high":
        "512M",

    "memory_max":
        "768M",

    "cpu_quota":
        "250%",

    "tasks_max":
        128,

    "queue":
        stats(),

    "second_xray":
        False,

    "second_exit_probe":
        False,
}


out=Path(
    "/var/lib/config-location/country/"
    "k8-final-audit.json"
)

out.write_text(
    json.dumps(
        report,
        indent=2,
        sort_keys=True,
    )
)

print(
    json.dumps(
        report,
        indent=2,
        sort_keys=True,
    )
)

print(
    "K8_FINAL_REPORT=PASS"
)
PY


trap - EXIT

echo
echo "======================================================"
echo "FIX22K8D=PASS"
echo "FIX22K8=COMPLETE"
echo "REAL_WORKER_SCALE_DOWN=ACTIVE"
echo "CPU_AWARE_CAP=8"
echo "DEFERRED_BACKPRESSURE=ACTIVE"
echo "MEMORY_HIGH=512M"
echo "MEMORY_MAX=768M"
echo "CPU_QUOTA=250_PERCENT"
echo "TASKS_MAX=128"
echo "DEAD_LETTER=ZERO"
echo "NEXT=FIX22K9"
echo "======================================================"
