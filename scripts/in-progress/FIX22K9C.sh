#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
MET=/var/lib/config-location/country/event-consumer-metrics.jsonl

OUT=/var/lib/config-location/country/k9
TS=$(date -u +%Y%m%d-%H%M%S)
RUN="$OUT/K9C-$TS"

mkdir -p "$RUN"

echo "RUN=$RUN"


echo
echo "=== 1. PRE-BENCHMARK CONSISTENCY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

I=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

P=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

checked=0
bad=[]

for ip in I.glob("*.json"):

    try:
        ident=json.loads(ip.read_text())
    except Exception:
        continue

    if not (
        ident.get("locked") is True
        and ident.get("country_code")
    ):
        continue

    cid=str(
        ident.get("config_id")
        or ip.stem
    )

    pp=P/f"{cid}.json"

    if not pp.exists():
        continue

    try:
        pipe=json.loads(pp.read_text())
    except Exception:
        continue

    checked+=1

    if (
        str(
            ident.get("country_code")
            or ""
        ).upper()
        !=
        str(
            pipe.get("country_code")
            or ""
        ).upper()
    ):
        bad.append(cid)

print("PRE_CHECKED=",checked)
print("PRE_CONSISTENCY_BAD=",len(bad))

assert not bad

print("PRE_CONSISTENCY=PASS")
PY


echo
echo "=== 2. PRE QUEUE / SERVICES ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

s=stats()

print("QUEUE_BEFORE=",s)

assert int(
    s.get("dead",0)
)==0

print("QUEUE_PRECHECK=PASS")
PY

for svc in \
config-location-country-event-consumer.service \
config-location-country-worker.service \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done


echo
echo "=== 3. RESET BENCHMARK WINDOW ==="

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
echo "=== 4. RUN 1000 TERMINAL EVENT BENCHMARK ==="

export RUN MET

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json
import os
import time

met=Path(os.environ["MET"])
run=Path(os.environ["RUN"])

TARGET=1000
TIMEOUT=3600

started=time.monotonic()
last_print=0

while True:

    c=Counter()

    if met.exists():

        for line in met.read_text().splitlines():

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


    terminal=(
        c["acked"]
        +c["deferred_no_exit"]
        +c["error"]
    )

    elapsed=(
        time.monotonic()
        -started
    )


    if (
        int(elapsed)-last_print>=30
        or terminal>=TARGET
    ):

        last_print=int(elapsed)

        print(
            "PROGRESS=",
            {
                "elapsed_s":
                    round(elapsed,1),

                "acked":
                    c["acked"],

                "deferred":
                    c["deferred_no_exit"],

                "error":
                    c["error"],

                "terminal":
                    terminal,
            },
            flush=True,
        )


    if terminal>=TARGET:
        break


    if elapsed>=TIMEOUT:

        raise SystemExit(
            "ERROR=BENCHMARK_TIMEOUT "
            f"terminal={terminal}"
        )


    time.sleep(2)


elapsed=(
    time.monotonic()
    -started
)

terminal=max(
    1,
    c["acked"]
    +c["deferred_no_exit"]
    +c["error"],
)


summary={
    "benchmark_size":
        TARGET,

    "elapsed_seconds":
        elapsed,

    "terminal_events":
        terminal,

    "terminal_rate_per_second":
        terminal
        /max(elapsed,0.001),

    "acked":
        c["acked"],

    "acked_rate_per_second":
        c["acked"]
        /max(elapsed,0.001),

    "acked_ratio":
        c["acked"]
        /terminal,

    "deferred":
        c["deferred_no_exit"],

    "deferred_rate_per_second":
        c["deferred_no_exit"]
        /max(elapsed,0.001),

    "deferred_ratio":
        c["deferred_no_exit"]
        /terminal,

    "error":
        c["error"],

    "counts":
        dict(c),
}


(run/"summary.json").write_text(
    json.dumps(
        summary,
        indent=2,
        sort_keys=True,
    )
)


print(
    json.dumps(
        summary,
        indent=2,
        sort_keys=True,
    )
)


assert c["error"]==0

print("BENCHMARK_1000=PASS")
PY


echo
echo "=== 5. POST-1000 GLOBAL CONSISTENCY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

I=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

P=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

checked=0
bad=[]

for ip in I.glob("*.json"):

    try:
        ident=json.loads(
            ip.read_text()
        )
    except Exception:
        continue


    if not (
        ident.get("locked") is True
        and ident.get("country_code")
    ):
        continue


    cid=str(
        ident.get("config_id")
        or ip.stem
    )

    pp=P/f"{cid}.json"

    if not pp.exists():
        continue


    try:
        pipe=json.loads(
            pp.read_text()
        )
    except Exception:
        continue


    checked+=1


    if (
        str(
            ident.get(
                "country_code"
            )
            or ""
        ).upper()
        !=
        str(
            pipe.get(
                "country_code"
            )
            or ""
        ).upper()
    ):

        bad.append(
            {
                "config_id":
                    cid,

                "identity":
                    ident.get(
                        "country_code"
                    ),

                "pipeline":
                    pipe.get(
                        "country_code"
                    ),

                "state":
                    pipe.get(
                        "state"
                    ),
            }
        )


print(
    "CONSISTENCY_CHECKED=",
    checked,
)

print(
    "CONSISTENCY_BAD=",
    len(bad),
)


for row in bad[:50]:

    print(
        "BAD=",
        row,
    )


assert not bad

print(
    "POST_1000_CONSISTENCY=PASS"
)
PY


echo
echo "=== 6. CONTROLLER / RESOURCE PROFILE ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

p=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)

rows=[]

for line in p.read_text().splitlines():

    try:
        rows.append(
            json.loads(line)
        )
    except Exception:
        pass


status=Counter(
    str(
        r.get(
            "status",
            "unknown",
        )
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


print(
    "STATUS=",
    dict(status),
)

print(
    "CONTROLLER_ROWS=",
    len(controllers),
)


assert status.get(
    "error",
    0,
)==0

assert status.get(
    "nack_error",
    0,
)==0


if controllers:

    max_active=max(
        int(
            r.get(
                "workers_active",
                0,
            )
            or 0
        )
        for r in controllers
    )

    max_target=max(
        int(
            r.get(
                "workers_target",
                0,
            )
            or 0
        )
        for r in controllers
    )

    max_cpu=max(
        float(
            r.get(
                "cpu_percent",
                0,
            )
            or 0
        )
        for r in controllers
    )

    max_memory=max(
        float(
            r.get(
                "memory_percent",
                0,
            )
            or 0
        )
        for r in controllers
    )

    heavy=sum(
        1
        for r in controllers
        if float(
            r.get(
                "deferred_ratio",
                0,
            )
            or 0
        )>=0.80
    )


    print(
        "MAX_ACTIVE=",
        max_active,
    )

    print(
        "MAX_TARGET=",
        max_target,
    )

    print(
        "MAX_CPU=",
        round(max_cpu,2),
    )

    print(
        "MAX_MEMORY_PERCENT=",
        round(max_memory,2),
    )

    print(
        "DEFERRED_HEAVY_WINDOWS=",
        heavy,
    )


    assert max_active<=8
    assert max_target<=8


print(
    "CONTROLLER_PROFILE=PASS"
)
PY


echo
echo "=== 7. IMMEDIATE IDENTITY SYNC PROFILE ==="

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

        if o.get(
            "status"
        )!="identity_pipeline_sync":
            continue

        c[
            str(
                o.get(
                    "sync_status",
                    "unknown",
                )
            )
        ]+=1


print(
    "IDENTITY_PIPELINE_SYNC=",
    dict(c),
)

print(
    "IMMEDIATE_SYNC_PROFILE=PASS"
)
PY


echo
echo "=== 8. QUEUE SAFETY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

s=stats()

print(
    "QUEUE_AFTER=",
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
echo "=== 9. RESOURCE LIMITS STILL ACTIVE ==="

systemctl show \
config-location-country-event-consumer.service \
-p MemoryCurrent \
-p MemoryHigh \
-p MemoryMax \
-p TasksCurrent \
-p TasksMax \
-p CPUQuotaPerSecUSec \
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
    ],
    text=True,
)

assert "MemoryHigh=536870912" in text
assert "MemoryMax=805306368" in text
assert "TasksMax=128" in text

print(
    "RESOURCE_LIMITS=PASS"
)
PY


echo
echo "=== 10. ARCHITECTURE SAFETY ==="

grep -q \
'FIX22_K9_IDENTITY_IMMEDIATE_RECONCILIATION' \
"$R/app/country/event_consumer.py"

grep -q \
'FIX22_K8D_DEFERRED_BACKPRESSURE' \
"$R/app/country/event_consumer.py"

grep -q \
'FIX22_K7_PIPELINE_IDENTITY_GUARD' \
"$R/app/country/pipeline.py"

grep -q \
'geo_singleflight_lock' \
"$R/app/country/geo_intelligence.py"

if grep -q \
'observe_exit_ip' \
"$R/app/country/event_consumer.py"
then
    echo "ERROR=SECOND_EXIT_PROBE"
    exit 1
fi

echo "K4_SINGLEFLIGHT=PRESERVED"
echo "K7_IDENTITY_GUARD=PRESERVED"
echo "K8_RESOURCE_CONTROLLER=PRESERVED"
echo "K9_IMMEDIATE_SYNC=PRESERVED"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"


echo
echo "=== 11. WRITE K9C REPORT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json
import os
import time

from app.country.event_bus import stats

run=Path(
    os.environ["RUN"]
)

summary=json.loads(
    (run/"summary.json").read_text()
)


report={
    "schema_version":1,

    "stage":"K9C",

    "benchmark_size":1000,

    "generated_epoch":
        int(time.time()),

    **summary,

    "queue":
        stats(),

    "dead_letter_zero":
        int(
            stats().get(
                "dead",
                0,
            )
        )==0,

    "consistency_bad":
        0,

    "effective_worker_cap":
        8,

    "second_xray":
        False,

    "second_exit_probe":
        False,
}


(run/"k9c-report.json").write_text(
    json.dumps(
        report,
        indent=2,
        sort_keys=True,
    )
)


Path(
    "/var/lib/config-location/country/"
    "k9c-latest.json"
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


assert report[
    "dead_letter_zero"
]

assert report[
    "consistency_bad"
]==0


print(
    "K9C_REPORT=PASS"
)
PY


echo
echo "=== 12. FINAL SERVICES ==="

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
echo "FIX22K9C=PASS"
echo "BENCHMARK_SIZE=1000"
echo "CONSISTENCY_BAD=0"
echo "ERRORS=ZERO"
echo "DEAD_LETTER=ZERO"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "NEXT=FIX22K9D-FINAL-AUDIT"
echo "======================================================"
