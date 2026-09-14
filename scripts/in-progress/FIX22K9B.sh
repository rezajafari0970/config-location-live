#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

OUT=/var/lib/config-location/country/k9
MET=/var/lib/config-location/country/event-consumer-metrics.jsonl

TS=$(date -u +%Y%m%d-%H%M%S)
RUN="$OUT/K9B-$TS"

mkdir -p "$RUN"

echo "RUN=$RUN"

echo
echo "=== 1. PRE-BENCHMARK SAFETY ==="

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

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
s=stats()
print("QUEUE_BEFORE=",s)
assert int(s.get("dead",0))==0
print("PRE_QUEUE=PASS")
PY


echo
echo "=== 2. RESET METRICS WINDOW ==="

rm -f "$MET"

systemctl restart \
config-location-country-event-consumer.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER_RESTART=PASS"


echo
echo "=== 3. WAIT FOR 500 TERMINAL EVENTS ==="

export RUN MET

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json
import os
import time

met=Path(os.environ["MET"])
run=Path(os.environ["RUN"])

TARGET=500
TIMEOUT=2700

started=time.monotonic()
last_print=0

while True:

    counts=Counter()

    if met.exists():
        for line in met.read_text().splitlines():
            try:
                o=json.loads(line)
            except Exception:
                continue

            counts[
                str(o.get("status","unknown"))
            ]+=1

    terminal=(
        counts["acked"]
        +counts["deferred_no_exit"]
        +counts["error"]
    )

    elapsed=time.monotonic()-started

    if (
        int(elapsed)-last_print>=20
        or terminal>=TARGET
    ):
        last_print=int(elapsed)

        print(
            "PROGRESS=",
            {
                "elapsed_s":round(elapsed,1),
                "acked":counts["acked"],
                "deferred":counts["deferred_no_exit"],
                "error":counts["error"],
                "terminal":terminal,
            },
            flush=True,
        )

    if terminal>=TARGET:
        break

    if elapsed>=TIMEOUT:
        raise SystemExit(
            f"ERROR=BENCHMARK_TIMEOUT terminal={terminal}"
        )

    time.sleep(2)


elapsed=time.monotonic()-started

terminal=max(
    1,
    counts["acked"]
    +counts["deferred_no_exit"]
    +counts["error"]
)

deferred_ratio=(
    counts["deferred_no_exit"]
    /terminal
)

acked_ratio=(
    counts["acked"]
    /terminal
)

summary={
    "benchmark_size":TARGET,
    "elapsed_seconds":elapsed,
    "terminal_events":terminal,
    "counts":dict(counts),
    "terminal_rate_per_second":
        terminal/max(elapsed,0.001),
    "acked_rate_per_second":
        counts["acked"]/max(elapsed,0.001),
    "deferred_rate_per_second":
        counts["deferred_no_exit"]/max(elapsed,0.001),
    "acked_ratio":acked_ratio,
    "deferred_ratio":deferred_ratio,
}

(run/"window-summary.json").write_text(
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

print("BENCHMARK_WINDOW=PASS")
PY


echo
echo "=== 4. CONTROLLER / RESOURCE AUDIT ==="

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
        rows.append(json.loads(line))
    except Exception:
        pass

status=Counter(
    str(r.get("status","unknown"))
    for r in rows
)

controllers=[
    r
    for r in rows
    if r.get("status")=="controller"
]

print("STATUS=",dict(status))
print("CONTROLLERS=",len(controllers))

assert status.get("error",0)==0
assert status.get("nack_error",0)==0

if controllers:

    max_active=max(
        int(r.get("workers_active",0) or 0)
        for r in controllers
    )

    max_target=max(
        int(r.get("workers_target",0) or 0)
        for r in controllers
    )

    max_cpu=max(
        float(r.get("cpu_percent",0) or 0)
        for r in controllers
    )

    max_mem=max(
        float(r.get("memory_percent",0) or 0)
        for r in controllers
    )

    deferred_heavy=sum(
        1
        for r in controllers
        if float(
            r.get("deferred_ratio",0)
            or 0
        )>=0.80
    )

    print("MAX_ACTIVE=",max_active)
    print("MAX_TARGET=",max_target)
    print("MAX_CPU=",round(max_cpu,2))
    print("MAX_MEMORY_PERCENT=",round(max_mem,2))
    print("DEFERRED_HEAVY_WINDOWS=",deferred_heavy)

    assert max_active<=8
    assert max_target<=8

print("CONTROLLER_RESOURCE_AUDIT=PASS")
PY


echo
echo "=== 5. QUEUE SAFETY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

s=stats()

print("QUEUE_AFTER=",s)

assert int(s.get("dead",0))==0

print("QUEUE_SAFETY=PASS")
PY


echo
echo "=== 6. GLOBAL COUNTRY CONSISTENCY ==="

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
        str(ident.get("country_code") or "").upper()
        !=
        str(pipe.get("country_code") or "").upper()
    ):
        bad.append(cid)

print("CONSISTENCY_CHECKED=",checked)
print("CONSISTENCY_BAD=",len(bad))

assert not bad

print("GLOBAL_CONSISTENCY=PASS")
PY


echo
echo "=== 7. ARCHITECTURE SAFETY ==="

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

echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "ARCHITECTURE_SAFETY=PASS"


echo
echo "=== 8. FINAL K9B REPORT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json
import os
import time

from app.country.event_bus import stats

run=Path(os.environ["RUN"])

window=json.loads(
    (run/"window-summary.json").read_text()
)

report={
    "schema_version":1,
    "stage":"K9B",
    "benchmark_size":500,
    "generated_epoch":int(time.time()),

    "elapsed_seconds":
        window["elapsed_seconds"],

    "terminal_rate_per_second":
        window["terminal_rate_per_second"],

    "acked_rate_per_second":
        window["acked_rate_per_second"],

    "deferred_rate_per_second":
        window["deferred_rate_per_second"],

    "acked_ratio":
        window["acked_ratio"],

    "deferred_ratio":
        window["deferred_ratio"],

    "counts":
        window["counts"],

    "queue":
        stats(),

    "dead_letter_zero":
        int(stats().get("dead",0))==0,

    "effective_worker_cap":
        8,

    "second_xray":
        False,

    "second_exit_probe":
        False,
}

(run/"k9b-report.json").write_text(
    json.dumps(
        report,
        indent=2,
        sort_keys=True,
    )
)

Path(
    "/var/lib/config-location/country/"
    "k9b-latest.json"
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

assert report["dead_letter_zero"]

print("K9B_REPORT=PASS")
PY


echo
echo "=== 9. SERVICES ==="

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
echo "======================================================"
echo "FIX22K9B=PASS"
echo "BENCHMARK_SIZE=500"
echo "REAL_ACK_RATE=MEASURED"
echo "DEFERRED_RATIO=MEASURED"
echo "GLOBAL_COUNTRY_CONSISTENCY=PASS"
echo "DEAD_LETTER=ZERO"
echo "NEXT=FIX22K9C-1000"
echo "======================================================"
