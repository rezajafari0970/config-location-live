#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
MET=/var/lib/config-location/country/event-consumer-metrics.jsonl
REPORT=/var/lib/config-location/country/consumer-c2-drain-benchmark.json

echo "=== 1. VERIFY CONSUMER ACTIVE ==="

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER=active"


echo
echo "=== 2. BASELINE SNAPSHOT ==="

export REPORT

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
import json
import os
import time
from pathlib import Path

s=stats()

baseline={
    "ts":time.time(),
    "queue":s,
}

Path(
    "/tmp/consumer-c2-baseline.json"
).write_text(
    json.dumps(
        baseline,
        indent=2,
    )
)

print(
    "BASELINE=",
    baseline,
)
PY


echo
echo "=== 3. OBSERVE 5 MINUTES ==="

for i in $(seq 1 20)
do
    sleep 15

    echo "--- T=$((i*15))s ---"

    PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print("QUEUE=",stats())
PY

    PID=$(
        systemctl show \
        config-location-country-event-consumer.service \
        -p MainPID \
        --value
    )

    echo "PID=$PID"

    if [ "$PID" -gt 0 ]; then
        ps -p "$PID" \
        -o %cpu,%mem,rss,vsz,etime \
        --no-headers || true

        echo "THREADS=$(
            ps -T -p "$PID" --no-headers | wc -l
        )"
    fi
done


echo
echo "=== 4. BENCHMARK ANALYSIS ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json
import time

from app.country.event_bus import stats

baseline=json.loads(
    Path(
        "/tmp/consumer-c2-baseline.json"
    ).read_text()
)

end=time.time()

start_ts=float(
    baseline["ts"]
)

duration=max(
    1.0,
    end-start_ts
)

before=baseline["queue"]
after=stats()

met=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)

rows=[]

if met.exists():

    for line in met.read_text().splitlines():

        try:
            r=json.loads(line)
        except Exception:
            continue

        if (
            int(
                r.get(
                    "ts_ns",
                    0,
                )
            )
            >= int(
                start_ts
                *1_000_000_000
            )
        ):
            rows.append(r)


status=Counter(
    r.get(
        "status",
        "unknown",
    )
    for r in rows
)


controllers=[
    r
    for r in rows
    if r.get(
        "status"
    )=="controller"
]


pending_before=int(
    before.get(
        "pending",
        0,
    )
)

pending_after=int(
    after.get(
        "pending",
        0,
    )
)

done_before=int(
    before.get(
        "done",
        0,
    )
)

done_after=int(
    after.get(
        "done",
        0,
    )
)


done_growth=max(
    0,
    done_after-done_before
)

net_pending_drop=(
    pending_before
    -pending_after
)


ack_count=status.get(
    "acked",
    0,
)

processed=status.get(
    "processed",
    0,
)

deferred=status.get(
    "deferred_no_exit",
    0,
)

errors=status.get(
    "error",
    0,
)


ack_per_sec=(
    ack_count
    /duration
)

done_per_sec=(
    done_growth
    /duration
)

net_drain_per_sec=(
    net_pending_drop
    /duration
)


# Estimate incoming events:
# pending_end = pending_start
# + incoming - completed/deferred-to-done effects.
#
# Using done growth as durable completed events:
incoming_estimate=max(
    0,
    (
        pending_after
        -pending_before
        +done_growth
    )
)

incoming_per_sec=(
    incoming_estimate
    /duration
)


eta_seconds=None

if net_drain_per_sec>0:

    eta_seconds=(
        pending_after
        /net_drain_per_sec
    )


max_live=0
max_target=0
max_cpu=0.0
max_mem=0.0

for r in controllers:

    max_live=max(
        max_live,
        int(
            r.get(
                "workers_live",
                0,
            )
            or 0
        ),
    )

    max_target=max(
        max_target,
        int(
            r.get(
                "workers_target",
                0,
            )
            or 0
        ),
    )

    max_cpu=max(
        max_cpu,
        float(
            r.get(
                "cpu_percent",
                0,
            )
            or 0
        ),
    )

    max_mem=max(
        max_mem,
        float(
            r.get(
                "memory_percent",
                0,
            )
            or 0
        ),
    )


report={
    "duration_seconds":
        round(
            duration,
            2,
        ),

    "queue_before":
        before,

    "queue_after":
        after,

    "metrics":{
        "processed":
            processed,

        "acked":
            ack_count,

        "deferred":
            deferred,

        "errors":
            errors,
    },

    "rates":{
        "ack_per_second":
            round(
                ack_per_sec,
                4,
            ),

        "done_per_second":
            round(
                done_per_sec,
                4,
            ),

        "net_drain_per_second":
            round(
                net_drain_per_sec,
                4,
            ),

        "estimated_incoming_per_second":
            round(
                incoming_per_sec,
                4,
            ),
    },

    "worker_controller":{
        "max_live":
            max_live,

        "max_target":
            max_target,

        "max_cpu_percent":
            round(
                max_cpu,
                2,
            ),

        "max_memory_percent":
            round(
                max_mem,
                2,
            ),
    },

    "estimated_seconds_to_empty":
        (
            round(
                eta_seconds,
                1,
            )
            if eta_seconds
            is not None
            else None
        ),
}


Path(
    "/var/lib/config-location/country/"
    "consumer-c2-drain-benchmark.json"
).write_text(
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


assert ack_count>=1
assert processed>=1
assert errors==0

# Must be making actual durable progress.
assert done_growth>=1

# Dead-letter must remain zero.
assert int(
    after.get(
        "dead",
        0,
    )
)==0

print(
    "CONSUMER_C2_BENCHMARK=PASS"
)
PY


echo
echo "=== 5. REPORT ==="

cat "$REPORT"


echo
echo "=== 6. SERVICES ==="

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
echo "FIX22K1_CONSUMER_C2=PASS"
echo "DRAIN_BENCHMARK=COMPLETE"
echo "REPORT=$REPORT"
echo "NEXT=K6-ROTATING-EXIT-HANDLING"
echo "======================================================"
