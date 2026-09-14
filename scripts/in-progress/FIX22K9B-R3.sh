#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
MET=/var/lib/config-location/country/event-consumer-metrics.jsonl

OUT=/var/lib/config-location/country/k9
TS=$(date -u +%Y%m%d-%H%M%S)
RUN="$OUT/K9B-R3-$TS"

mkdir -p "$RUN"

echo "RUN=$RUN"


echo "=== 1. PRECHECK ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

I=Path("/var/lib/config-location/country/country-identity")
P=Path("/var/lib/config-location/country/pipeline/latest")

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

    cid=str(ident.get("config_id") or ip.stem)
    pp=P/f"{cid}.json"

    if not pp.exists():
        continue

    try:
        pipe=json.loads(pp.read_text())
    except Exception:
        continue

    if (
        str(ident.get("country_code") or "").upper()
        !=
        str(pipe.get("country_code") or "").upper()
    ):
        bad.append(cid)

print("PRE_CONSISTENCY_BAD=",len(bad))
assert not bad

print("PRECHECK=PASS")
PY


echo "=== 2. RESET METRICS ==="

rm -f "$MET"

systemctl restart \
config-location-country-event-consumer.service

sleep 5

test "$(
  systemctl is-active \
  config-location-country-event-consumer.service
)" = active


echo "=== 3. RUN 500 TERMINAL EVENT WINDOW ==="

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

    c=Counter()

    if met.exists():
        for line in met.read_text().splitlines():
            try:
                o=json.loads(line)
            except Exception:
                continue

            c[str(o.get("status","unknown"))]+=1

    terminal=(
        c["acked"]
        +c["deferred_no_exit"]
        +c["error"]
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
                "acked":c["acked"],
                "deferred":c["deferred_no_exit"],
                "error":c["error"],
                "terminal":terminal,
            },
            flush=True,
        )

    if terminal>=TARGET:
        break

    if elapsed>=TIMEOUT:
        raise SystemExit(
            f"ERROR=TIMEOUT terminal={terminal}"
        )

    time.sleep(2)


elapsed=time.monotonic()-started

summary={
    "elapsed_seconds":elapsed,
    "terminal_events":terminal,
    "terminal_rate":
        terminal/max(elapsed,0.001),
    "acked":
        c["acked"],
    "acked_rate":
        c["acked"]/max(elapsed,0.001),
    "deferred":
        c["deferred_no_exit"],
    "deferred_ratio":
        c["deferred_no_exit"]/max(1,terminal),
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

print("BENCHMARK_500=PASS")
PY


echo "=== 4. POST CONSISTENCY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

I=Path("/var/lib/config-location/country/country-identity")
P=Path("/var/lib/config-location/country/pipeline/latest")

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

    cid=str(ident.get("config_id") or ip.stem)
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
        bad.append(
            {
                "config_id":cid,
                "identity":
                    ident.get("country_code"),
                "pipeline":
                    pipe.get("country_code"),
                "state":
                    pipe.get("state"),
            }
        )

print("CONSISTENCY_CHECKED=",checked)
print("CONSISTENCY_BAD=",len(bad))

for row in bad[:30]:
    print("BAD=",row)

assert not bad

print("POST_CONSISTENCY=PASS")
PY


echo "=== 5. CONTROLLER SAFETY ==="

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

c=Counter(
    str(x.get("status","unknown"))
    for x in rows
)

ctrl=[
    x for x in rows
    if x.get("status")=="controller"
]

print("STATUS=",dict(c))

assert c["error"]==0
assert c["nack_error"]==0

if ctrl:
    max_active=max(
        int(x.get("workers_active",0) or 0)
        for x in ctrl
    )
    max_target=max(
        int(x.get("workers_target",0) or 0)
        for x in ctrl
    )
    max_cpu=max(
        float(x.get("cpu_percent",0) or 0)
        for x in ctrl
    )

    print("MAX_ACTIVE=",max_active)
    print("MAX_TARGET=",max_target)
    print("MAX_CPU=",round(max_cpu,2))

    assert max_active<=8
    assert max_target<=8

print("CONTROLLER_SAFETY=PASS")
PY


echo "=== 6. QUEUE SAFETY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

s=stats()
print("QUEUE=",s)

assert int(s.get("dead",0))==0

print("QUEUE_SAFETY=PASS")
PY


echo "=== 7. SERVICES ==="

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


echo "======================================================"
echo "FIX22K9B_R3=PASS"
echo "BENCHMARK_SIZE=500"
echo "CONSISTENCY_BAD=0"
echo "DEAD_LETTER=ZERO"
echo "NEXT=FIX22K9C-1000"
echo "======================================================"
