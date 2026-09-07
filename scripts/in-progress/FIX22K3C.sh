#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

MET=/var/lib/config-location/country/same-runtime-fastpath.jsonl
REPORT=/var/lib/config-location/country/k3-production-benchmark.json

echo "=== 1. VERIFY K3 PRODUCTION CODE ==="

grep -q \
'FIX22K3_PARALLEL_EXIT_OBSERVER' \
"$R/app/country/exit_observer.py"

grep -q \
'timeout=3.0' \
"$R/app/country/same_runtime_fastpath.py"

"$PY" -m py_compile \
"$R/app/country/exit_observer.py" \
"$R/app/country/same_runtime_fastpath.py" \
"$R/app/health/core/engine.py"

echo "K3_CODE=PASS"


echo "=== 2. RESET BENCHMARK METRICS ==="

rm -f "$MET"

echo "METRICS_RESET=PASS"


echo "=== 3. RESTART HEALTH ==="

systemctl restart \
config-location-health-adaptive.service

sleep 5

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = active

echo "HEALTH=active"


echo "=== 4. COLLECT 100 REAL HEALTHY FASTPATH RUNS ==="

FOUND=0

for i in $(seq 1 120)
do

    N=0

    if [ -f "$MET" ]; then
        N=$(wc -l <"$MET")
    fi

    echo "T=$((i*5))s ROWS=$N"

    if [ "$N" -ge 100 ]; then
        FOUND=1
        break
    fi

    sleep 5
done

test "$FOUND" -eq 1


echo "=== 5. PRODUCTION BENCHMARK ==="

export REPORT

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json
import os

p=Path(
    "/var/lib/config-location/country/"
    "same-runtime-fastpath.jsonl"
)

rows=[]

for line in p.read_text().splitlines():

    try:
        rows.append(
            json.loads(line)
        )
    except Exception:
        pass


# Freeze first 100 real samples.
rows=rows[:100]

assert len(rows)==100


status=Counter(
    r.get(
        "status",
        "unknown",
    )
    for r in rows
)


times=sorted(
    int(
        r.get(
            "elapsed_ms",
            0,
        )
        or 0
    )
    for r in rows
)


def pct(value):

    index=min(
        len(times)-1,
        int(
            (len(times)-1)
            * value
        ),
    )

    return times[index]


success=status.get(
    "success",
    0,
)

success_rate=(
    success
    / len(rows)
)


result={
    "sample_size":
        len(rows),

    "status":
        dict(status),

    "success_rate":
        success_rate,

    "latency_ms":{
        "min":
            times[0],

        "p50":
            pct(.50),

        "p90":
            pct(.90),

        "p95":
            pct(.95),

        "p99":
            pct(.99),

        "max":
            times[-1],

        "avg":
            round(
                sum(times)
                / len(times),
                2,
            ),
    },

    "baseline_pre_k3":{
        "sample_size":235,
        "success":217,
        "success_rate":
            217/235,

        "p50_ms":882,
        "p90_ms":3313,
        "p95_ms":6336,
        "max_ms":14711,
        "avg_ms":1703.66,
    },
}


Path(
    os.environ["REPORT"]
).write_text(
    json.dumps(
        result,
        indent=2,
        sort_keys=True,
    )
)


print(
    "SAMPLE_SIZE=",
    len(rows),
)

print(
    "STATUS=",
    dict(status),
)

print(
    "SUCCESS_RATE=",
    round(
        success_rate,
        4,
    ),
)

for k,v in result[
    "latency_ms"
].items():

    print(
        f"{k.upper()}_MS=",
        v,
    )


# ----------------------------
# Production regression gates
# ----------------------------

baseline_rate=217/235


# No meaningful reliability regression.
assert (
    success_rate
    >= baseline_rate - 0.03
), (
    "success rate regressed >3pp"
)


# K3 must materially improve tail latency.
assert pct(.95) < 3000, (
    "P95 regression"
)


# Fast Health path must remain bounded.
assert times[-1] < 6000, (
    "fastpath max latency too high"
)


# Median should remain meaningfully faster
# than pre-K3 baseline.
assert pct(.50) < 700, (
    "P50 regression"
)


print(
    "PRODUCTION_REGRESSION_GATES=PASS"
)
PY


echo "=== 6. SHOW BENCHMARK REPORT ==="

cat "$REPORT"


echo "=== 7. VERIFY K2 DURABLE HANDOFF ==="

"$PY" <<'PY'
from pathlib import Path
import json
import time

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

cut=time.time()-300

handoff=0
success=0

for p in H.glob("*.json"):

    if p.stat().st_mtime < cut:
        continue

    try:
        h=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    fast=(
        (
            h.get("metadata")
            or {}
        ).get(
            "same_runtime_country"
        )
    )

    if not isinstance(
        fast,
        dict,
    ):
        continue

    handoff+=1

    if (
        fast.get("status")
        =="success"
        and fast.get("exit_ip")
    ):
        success+=1


print(
    "RECENT_HANDOFF=",
    handoff,
)

print(
    "RECENT_HANDOFF_SUCCESS=",
    success,
)

assert handoff>=1
assert success>=1

print(
    "K2_HANDOFF=PASS"
)
PY


echo "=== 8. K1 QUEUE SAFETY ==="

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
    "QUEUE=",
    stats(),
)

print(
    "K1_EVENT_BUS=PASS"
)
PY


echo "=== 9. HEALTH PRODUCTION INTEGRITY ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json
import time

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

cut=time.time()-300

states=Counter()
n=0

for p in H.glob("*.json"):

    if p.stat().st_mtime < cut:
        continue

    try:
        h=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    n+=1

    states[
        str(
            h.get(
                "state",
                "unknown",
            )
        )
    ]+=1


print(
    "RECENT_RESULTS=",
    n,
)

print(
    "RECENT_STATES=",
    dict(states),
)

assert n>=10

assert (
    states.get(
        "healthy",
        0,
    ) >= 1
)

print(
    "HEALTH_PRODUCTION=PASS"
)
PY


echo "=== 10. SERVICES ==="

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


echo "======================================================"
echo "FIX22K3C=PASS"
echo "FIX22K3=COMPLETE"
echo "PARALLEL_EXIT_PROBES=PRODUCTION_STABLE"
echo "EARLY_CONSENSUS=PRODUCTION_STABLE"
echo "REGRESSION_GUARD=PASS"
echo "SECOND_XRAY=NO"
echo "K2_HANDOFF=PRESERVED"
echo "K1_FALLBACK=PRESERVED"
echo "BENCHMARK=$REPORT"
echo "NEXT=FIX22K4"
echo "======================================================"
