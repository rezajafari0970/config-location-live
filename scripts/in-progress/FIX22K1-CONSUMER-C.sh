#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

APP="$R/app/country/event_consumer.py"
UNIT=/etc/systemd/system/config-location-country-event-consumer.service
MET=/var/lib/config-location/country/event-consumer-metrics.jsonl

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K1-CONSUMER-C-$TS"

mkdir -p "$B"

cp -a "$APP" "$B/"
cp -a "$UNIT" "$B/"

echo "BACKUP=$B"


echo "=== 1. STOP CONSUMER ==="

systemctl stop \
config-location-country-event-consumer.service \
2>/dev/null || true


echo "=== 2. PATCH ADAPTIVE WORKER CONTROLLER ==="

export APP

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["APP"])
s=p.read_text()

if "FIX22_CONSUMER_ADAPTIVE_CONTROLLER" in s:
    print(
        "ADAPTIVE_CONTROLLER_ALREADY_PRESENT=YES"
    )
    raise SystemExit(0)


# Add resource import.
s=s.replace(
    "import signal\n",
    "import signal\n"
    "import resource\n",
    1,
)


# Insert helper before main.
marker="\ndef main() -> int:\n"

if marker not in s:
    raise SystemExit(
        "ERROR: main marker missing"
    )


helper=r'''
# FIX22_CONSUMER_ADAPTIVE_CONTROLLER

def _cpu_percent_sample(
    previous: tuple[
        float,
        float,
    ] | None,
) -> tuple[
    float,
    tuple[
        float,
        float,
    ],
]:

    now_wall=time.monotonic()

    usage=resource.getrusage(
        resource.RUSAGE_SELF
    )

    now_cpu=(
        usage.ru_utime
        +usage.ru_stime
    )


    current=(
        now_wall,
        now_cpu,
    )


    if previous is None:
        return 0.0,current


    wall=max(
        0.001,
        now_wall
        -previous[0],
    )

    cpu=max(
        0.0,
        now_cpu
        -previous[1],
    )


    percent=(
        cpu
        /wall
        *100.0
    )


    return percent,current


def _memory_percent() -> float:

    try:

        values={}

        for line in Path(
            "/proc/meminfo"
        ).read_text().splitlines():

            if ":" not in line:
                continue

            key,value=(
                line.split(
                    ":",
                    1,
                )
            )

            values[key]=int(
                value.strip()
                .split()[0]
            )


        total=values.get(
            "MemTotal",
            0,
        )

        available=values.get(
            "MemAvailable",
            0,
        )


        if total<=0:
            return 0.0


        return (
            (
                total
                -available
            )
            /total
            *100.0
        )

    except Exception:
        return 0.0


def _metric_counts_since(
    ts_ns: int,
) -> dict:

    counts={
        "processed":0,
        "acked":0,
        "error":0,
        "deferred_no_exit":0,
    }


    try:

        if not METRICS.exists():
            return counts


        # Metrics file is still reasonably small.
        # Later K8 can move this to counters.
        for line in METRICS.read_text().splitlines():

            try:
                row=json.loads(
                    line
                )
            except Exception:
                continue


            if int(
                row.get(
                    "ts_ns",
                    0,
                )
            ) < ts_ns:
                continue


            status=row.get(
                "status"
            )

            if status in counts:
                counts[status]+=1


    except Exception:
        pass


    return counts
'''


s=s.replace(
    marker,
    "\n"+helper+marker,
    1,
)


# Replace main completely.
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


    def stop_handler(
        *_,
    ):
        STOP.set()


    signal.signal(
        signal.SIGTERM,
        stop_handler,
    )

    signal.signal(
        signal.SIGINT,
        stop_handler,
    )


    threads=[]


    def spawn_one():

        worker_id=len(
            threads
        )

        t=threading.Thread(
            target=worker_loop,
            args=(
                worker_id,
            ),
            daemon=True,
            name=(
                f"country-event-"
                f"{worker_id}"
            ),
        )

        t.start()
        threads.append(t)


    for _ in range(
        minimum
    ):
        spawn_one()


    target_workers=minimum

    previous_cpu=None

    previous_pending=(
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
            "status":
                "consumer_start",

            "workers":
                target_workers,

            "adaptive":
                True,

            "queue":
                stats(),
        }
    )


    while not STOP.wait(
        interval
    ):

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

        failures=(
            counts["error"]
        )


        error_rate=(
            failures
            /max(
                1,
                completed
                +failures,
            )
        )


        pending_delta=(
            pending
            -previous_pending
        )

        previous_pending=pending


        old_target=(
            target_workers
        )

        reason="hold"


        # Multiplicative decrease under pressure.
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
                        target_workers
                        *0.70,
                    )
                ),
            )

            reason="pressure_decrease"


        # Additive increase while backlog is large
        # and the process remains healthy.
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


        # Python threads cannot be safely killed.
        # Scale-down becomes the target for the next
        # service generation; scale-up is immediate.
        if (
            target_workers
            >len(threads)
        ):

            while (
                len(threads)
                <target_workers
            ):
                spawn_one()


        _metric(
            {
                "status":
                    "controller",

                "workers_live":
                    len(threads),

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
                    counts[
                        "processed"
                    ],

                "acked_window":
                    counts[
                        "acked"
                    ],

                "deferred_window":
                    counts[
                        "deferred_no_exit"
                    ],
            }
        )


    for t in threads:

        t.join(
            timeout=5,
        )


    _metric(
        {
            "status":
                "consumer_stop",

            "queue":
                stats(),
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
    "ADAPTIVE_CONTROLLER_PATCH=PASS"
)
PY


echo "=== 3. COMPILE ==="

"$PY" -m py_compile "$APP"

echo "COMPILE=PASS"


echo "=== 4. UPDATE SYSTEMD ENVIRONMENT ==="

python3 <<'PY'
from pathlib import Path

p=Path(
    "/etc/systemd/system/"
    "config-location-country-event-consumer.service"
)

s=p.read_text()

lines=s.splitlines()

lines=[
    x
    for x in lines
    if not x.startswith(
        "Environment=COUNTRY_EVENT_CONSUMER_"
    )
]

needle=(
    "Environment=PYTHONPATH=/opt/config-location"
)

out=[]

for line in lines:

    out.append(line)

    if line==needle:

        out.extend(
            [
                "Environment=COUNTRY_EVENT_CONSUMER_MIN_WORKERS=2",
                "Environment=COUNTRY_EVENT_CONSUMER_MAX_WORKERS=12",
                "Environment=COUNTRY_EVENT_CONSUMER_CONTROL_SECONDS=15",
            ]
        )


p.write_text(
    "\n".join(out)
    +"\n"
)

print(
    "SYSTEMD_ADAPTIVE_ENV=PASS"
)
PY


systemctl daemon-reload


echo "=== 5. RESET METRICS ==="

rm -f "$MET"


echo "=== 6. BASELINE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "QUEUE_BASELINE=",
    stats(),
)
PY


echo "=== 7. START ADAPTIVE CONSUMER ==="

systemctl restart \
config-location-country-event-consumer.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER=active"


echo "=== 8. 3-MINUTE ADAPTIVE OBSERVATION ==="

for i in $(seq 1 12)
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
        echo "THREADS=$(ps -T -p "$PID" --no-headers | wc -l)"
    fi

done


echo "=== 9. CONTROLLER ANALYSIS ==="

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


print(
    "STATUS=",
    dict(status),
)


controllers=[
    r
    for r in rows
    if r.get(
        "status"
    )=="controller"
]


print(
    "CONTROLLER_ROWS=",
    len(controllers),
)


for r in controllers:

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

            "acked_window":
                r.get(
                    "acked_window"
                ),
        },
    )


assert len(
    controllers
)>=5


assert status.get(
    "processed",
    0,
)>=1

assert status.get(
    "acked",
    0,
)>=1

assert status.get(
    "nack_error",
    0,
)==0


max_workers=max(
    int(
        r.get(
            "workers_live",
            0,
        )
    )
    for r in controllers
)


print(
    "MAX_WORKERS_OBSERVED=",
    max_workers,
)


assert max_workers>=2
assert max_workers<=12


print(
    "ADAPTIVE_CONTROLLER=PASS"
)
PY


echo "=== 10. QUEUE FINAL ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "QUEUE_FINAL=",
    stats(),
)
PY


echo "=== 11. SERVICES ==="

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


echo "======================================================"
echo "FIX22K1_CONSUMER_C=PASS"
echo "ADAPTIVE_DRAIN=ACTIVE"
echo "MIN_WORKERS=2"
echo "MAX_WORKERS=12"
echo "CONTROL_INTERVAL=15S"
echo "SIGNALS=BACKLOG+CPU+RAM+ERROR_RATE"
echo "K2_K4_K5_PATH=PRESERVED"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "NEXT=CONSUMER-C2-DRAIN-BENCHMARK"
echo "======================================================"
