#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
APP="$R/app/country/event_consumer.py"
MET=/var/lib/config-location/country/event-consumer-metrics.jsonl

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K8B-$TS"

mkdir -p "$B"
cp -a "$APP" "$B/"

echo "BACKUP=$B"

restore_service() {
    systemctl restart \
        config-location-country-event-consumer.service \
        >/dev/null 2>&1 || true
}

trap restore_service EXIT


echo "=== 1. STOP CONSUMER ==="

systemctl stop \
config-location-country-event-consumer.service

echo "CONSUMER_STOPPED=YES"


echo "=== 2. PATCH GRACEFUL RETIREMENT ==="

export APP

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["APP"])
s=p.read_text()

if "FIX22_K8_REAL_WORKER_RETIREMENT" in s:
    print("K8_RETIREMENT_ALREADY_PRESENT=YES")
    raise SystemExit(0)


# --------------------------------------------------
# Replace worker loop
# --------------------------------------------------

start=s.index(
    "def worker_loop("
)

end=s.index(
    "\n\n# FIX22_CONSUMER_ADAPTIVE_CONTROLLER",
    start,
)

old=s[start:end]

# Preserve the existing worker body, but add a
# per-worker retirement event and safe boundary.
old=old.replace(
    '''def worker_loop(
    worker_id: int,
) -> None:''',
    '''def worker_loop(
    worker_id: int,
    retire_event: threading.Event | None = None,
) -> None:''',
    1,
)

old=old.replace(
    '''    while not STOP.is_set():

        lease_path=None''',
    '''    # FIX22_K8_REAL_WORKER_RETIREMENT
    #
    # Retirement is checked only before acquiring
    # the next lease. A worker already processing an
    # event always finishes ACK/NACK first.
    while not STOP.is_set():

        if (
            retire_event is not None
            and retire_event.is_set()
        ):
            _metric(
                {
                    "status":"worker_retired",
                    "worker_id":worker_id,
                    "reason":"controller_scale_down",
                }
            )
            return

        lease_path=None''',
    1,
)

# When queue is empty, allow retirement to wake the
# worker promptly instead of waiting for another job.
old=old.replace(
    '''            if leased is None:

                STOP.wait(
                    0.20
                )
                continue''',
    '''            if leased is None:

                if (
                    retire_event is not None
                    and retire_event.wait(0.20)
                ):
                    _metric(
                        {
                            "status":"worker_retired",
                            "worker_id":worker_id,
                            "reason":"idle_retirement",
                        }
                    )
                    return

                if STOP.is_set():
                    return

                continue''',
    1,
)

s=s[:start]+old+s[end:]


# --------------------------------------------------
# Replace adaptive main
# --------------------------------------------------

start=s.index(
    "def main() -> int:"
)

end=s.index(
    '\n\nif __name__=="__main__":',
    start,
)

new_main=r'''def main() -> int:

    minimum=max(
        1,
        int(
            os.getenv(
                "COUNTRY_EVENT_CONSUMER_MIN_WORKERS",
                "2",
            )
        ),
    )

    maximum=max(
        minimum,
        int(
            os.getenv(
                "COUNTRY_EVENT_CONSUMER_MAX_WORKERS",
                "12",
            )
        ),
    )

    interval=max(
        5,
        int(
            os.getenv(
                "COUNTRY_EVENT_CONSUMER_CONTROL_SECONDS",
                "15",
            )
        ),
    )


    def stop_handler(*_):
        STOP.set()


    signal.signal(
        signal.SIGTERM,
        stop_handler,
    )

    signal.signal(
        signal.SIGINT,
        stop_handler,
    )


    # worker_id -> {
    #   thread,
    #   retire_event,
    #   retiring,
    # }
    workers={}

    next_worker_id=0


    def cleanup_workers():

        dead=[]

        for worker_id,item in workers.items():

            t=item["thread"]

            if not t.is_alive():
                dead.append(worker_id)

        for worker_id in dead:

            item=workers.pop(
                worker_id
            )

            try:
                item["thread"].join(
                    timeout=0
                )
            except Exception:
                pass


    def active_workers():

        cleanup_workers()

        return [
            (worker_id,item)
            for worker_id,item
            in workers.items()
            if (
                item["thread"].is_alive()
                and not item[
                    "retire_event"
                ].is_set()
            )
        ]


    def retiring_workers():

        cleanup_workers()

        return [
            (worker_id,item)
            for worker_id,item
            in workers.items()
            if (
                item["thread"].is_alive()
                and item[
                    "retire_event"
                ].is_set()
            )
        ]


    def spawn_one():

        nonlocal next_worker_id

        worker_id=next_worker_id
        next_worker_id+=1

        retire_event=threading.Event()

        t=threading.Thread(
            target=worker_loop,
            args=(
                worker_id,
                retire_event,
            ),
            daemon=True,
            name=(
                f"country-event-"
                f"{worker_id}"
            ),
        )

        workers[worker_id]={
            "thread":t,
            "retire_event":
                retire_event,
        }

        t.start()

        _metric(
            {
                "status":"worker_spawned",
                "worker_id":worker_id,
            }
        )


    def request_retirement(
        count: int,
    ) -> int:

        if count<=0:
            return 0

        candidates=sorted(
            active_workers(),
            key=lambda pair:pair[0],
            reverse=True,
        )

        retired=0

        for worker_id,item in candidates:

            if retired>=count:
                break

            item[
                "retire_event"
            ].set()

            retired+=1

            _metric(
                {
                    "status":
                        "worker_retire_requested",

                    "worker_id":
                        worker_id,
                }
            )

        return retired


    for _ in range(minimum):
        spawn_one()


    target_workers=minimum

    previous_cpu=None

    previous_pending=int(
        stats().get(
            "pending",
            0,
        )
    )

    window_start_ns=(
        time.time_ns()
    )


    _metric(
        {
            "status":"consumer_start",
            "workers":target_workers,
            "adaptive":True,
            "real_scale_down":True,
            "queue":stats(),
        }
    )


    while not STOP.wait(
        interval
    ):

        cleanup_workers()

        q=stats()

        pending=int(
            q.get(
                "pending",
                0,
            )
        )

        leased=int(
            q.get(
                "leased",
                0,
            )
        )


        cpu_percent,previous_cpu=(
            _cpu_percent_sample(
                previous_cpu
            )
        )

        memory_percent=(
            _memory_percent()
        )

        counts=(
            _metric_counts_since(
                window_start_ns
            )
        )

        window_start_ns=(
            time.time_ns()
        )


        completed=max(
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

        pending_delta=(
            pending
            -previous_pending
        )

        previous_pending=pending

        old_target=target_workers
        reason="hold"


        # AIMD:
        # multiplicative decrease under pressure.
        if (
            cpu_percent>=80.0
            or memory_percent>=88.0
            or error_rate>=0.08
        ):

            target_workers=max(
                minimum,
                int(
                    max(
                        minimum,
                        target_workers*0.70,
                    )
                ),
            )

            reason="pressure_decrease"


        # Additive increase only when comfortably
        # below CPU/memory pressure.
        elif (
            pending>=500
            and cpu_percent<65.0
            and memory_percent<82.0
            and error_rate<0.03
        ):

            target_workers=min(
                maximum,
                target_workers+1,
            )

            reason="backlog_increase"


        elif (
            pending<100
            and target_workers>minimum
        ):

            target_workers=max(
                minimum,
                target_workers-1,
            )

            reason="queue_low"


        active=len(
            active_workers()
        )


        # Real scale-up.
        while (
            active<target_workers
        ):

            spawn_one()

            active=len(
                active_workers()
            )


        # Real graceful scale-down.
        if active>target_workers:

            request_retirement(
                active-target_workers
            )


        cleanup_workers()

        active_count=len(
            active_workers()
        )

        retiring_count=len(
            retiring_workers()
        )

        physical_live=sum(
            1
            for item in workers.values()
            if item["thread"].is_alive()
        )


        _metric(
            {
                "status":"controller",

                "workers_live":
                    physical_live,

                "workers_active":
                    active_count,

                "workers_retiring":
                    retiring_count,

                "workers_target":
                    target_workers,

                "workers_previous_target":
                    old_target,

                "reason":
                    reason,

                "pending":
                    pending,

                "leased":
                    leased,

                "pending_delta":
                    pending_delta,

                "cpu_percent":
                    round(
                        cpu_percent,
                        2,
                    ),

                "memory_percent":
                    round(
                        memory_percent,
                        2,
                    ),

                "error_rate":
                    round(
                        error_rate,
                        4,
                    ),

                "processed_window":
                    counts["processed"],

                "acked_window":
                    counts["acked"],

                "deferred_window":
                    counts[
                        "deferred_no_exit"
                    ],

                "real_scale_down":
                    True,
            }
        )


    # Global shutdown.
    for item in workers.values():
        item[
            "retire_event"
        ].set()


    for item in workers.values():

        item["thread"].join(
            timeout=5,
        )


    _metric(
        {
            "status":"consumer_stop",
            "queue":stats(),
        }
    )

    return 0
'''

s=(
    s[:start]
    +new_main
    +s[end:]
)

p.write_text(s)

print(
    "K8_REAL_RETIREMENT_PATCH=PASS"
)
PY


echo "=== 3. COMPILE ==="

"$PY" -m py_compile "$APP"

echo "COMPILE=PASS"


echo "=== 4. STATIC CONTRACT ==="

grep -q \
'FIX22_K8_REAL_WORKER_RETIREMENT' \
"$APP"

grep -q \
'worker_retire_requested' \
"$APP"

grep -q \
'worker_retired' \
"$APP"

grep -q \
'workers_retiring' \
"$APP"

echo "RETIREMENT_CODE=PASS"


echo "=== 5. RESET OBSERVATION METRICS ==="

rm -f "$MET"


echo "=== 6. START CONSUMER ==="

systemctl restart \
config-location-country-event-consumer.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER=active"


echo "=== 7. 4-MINUTE LIVE ADAPTIVE TEST ==="

for i in $(seq 1 24)
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

    if [ "$PID" -gt 0 ]; then

        ps -p "$PID" \
        -o %cpu,%mem,rss,nlwp,etime \
        --no-headers || true

        echo "THREADS=$(
            ps -T -p "$PID" \
            --no-headers \
            | wc -l
        )"
    fi

    PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print("QUEUE=",stats())
PY
done


echo "=== 8. RETIREMENT ANALYSIS ==="

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
    if r.get("status")=="controller"
]


print(
    "STATUS=",
    dict(status),
)

print(
    "CONTROLLER_ROWS=",
    len(controllers),
)

for r in controllers:

    print(
        "CONTROL=",
        {
            "live":
                r.get("workers_live"),

            "active":
                r.get("workers_active"),

            "retiring":
                r.get(
                    "workers_retiring"
                ),

            "target":
                r.get("workers_target"),

            "reason":
                r.get("reason"),

            "pending":
                r.get("pending"),

            "cpu":
                r.get("cpu_percent"),

            "memory":
                r.get(
                    "memory_percent"
                ),

            "error_rate":
                r.get("error_rate"),
        },
    )


assert len(controllers)>=8

assert status.get(
    "processed",
    0,
)>=1

assert status.get(
    "acked",
    0,
)>=1

assert status.get(
    "error",
    0,
)==0

assert status.get(
    "nack_error",
    0,
)==0


# Core contract:
# if retirement was requested, at least one worker
# must actually exit.
requested=status.get(
    "worker_retire_requested",
    0,
)

retired=status.get(
    "worker_retired",
    0,
)

print(
    "RETIRE_REQUESTED=",
    requested,
)

print(
    "RETIRE_COMPLETED=",
    retired,
)


if requested>0:
    assert retired>=1


# Active workers may not remain above target after
# retirement has had time to settle, except while a
# currently leased worker is finishing safely.
settled=[
    r
    for r in controllers[-5:]
    if (
        int(
            r.get(
                "workers_retiring",
                0,
            )
            or 0
        )==0
    )
]

for r in settled:

    active=int(
        r.get(
            "workers_active",
            0,
        )
        or 0
    )

    target=int(
        r.get(
            "workers_target",
            0,
        )
        or 0
    )

    assert active<=target


print(
    "REAL_WORKER_RETIREMENT=PASS"
)
PY


echo "=== 9. QUEUE SAFETY ==="

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


echo "=== 10. SERVICES ==="

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


trap - EXIT

echo "======================================================"
echo "FIX22K8B=PASS"
echo "REAL_SCALE_DOWN=ACTIVE"
echo "RETIREMENT_BOUNDARY=BETWEEN_LEASES"
echo "INFLIGHT_JOB=FINISH_BEFORE_RETIRE"
echo "LEASE_LOSS=NO"
echo "DEAD_LETTER=ZERO"
echo "NEXT=FIX22K8C-BACKPRESSURE-RESOURCE-LIMITS"
echo "======================================================"
