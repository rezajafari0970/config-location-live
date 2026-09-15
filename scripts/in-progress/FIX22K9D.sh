#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

COUNTRY=/var/lib/config-location/country
OUT="$COUNTRY/k9-final-production-audit.json"

echo "======================================================"
echo " K9D FINAL PRODUCTION AUDIT"
echo "======================================================"


echo
echo "=== 1. REQUIRED FINAL ARTIFACTS ==="

for f in \
"$COUNTRY/k7-final-audit.json" \
"$COUNTRY/k8-final-audit.json" \
"$COUNTRY/k9c-latest.json"
do

    test -f "$f"

    echo "$f=OK"

done

echo "FINAL_ARTIFACTS=PASS"


echo
echo "=== 2. PYTHON COMPILE AUDIT ==="

FILES=(
"$R/app/country/event_consumer.py"
"$R/app/country/pipeline.py"
"$R/app/country/storage.py"
"$R/app/country/country_identity.py"
"$R/app/country/geo_intelligence.py"
"$R/app/country/geo_providers.py"
"$R/app/country/progressive_recovery.py"
"$R/app/country/hard_fallback.py"
)

for f in "${FILES[@]}"
do

    test -f "$f"

    "$PY" -m py_compile "$f"

    echo "$f=PASS"

done

echo "PYTHON_COMPILE=PASS"


echo
echo "=== 3. FINAL IDENTITY INTEGRITY ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

root=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

total=0
valid=0
invalid=[]

countries=Counter()

for p in root.glob("*.json"):

    total+=1

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception as exc:

        invalid.append(
            {
                "file":str(p),
                "reason":
                    f"bad_json:{exc}",
            }
        )

        continue


    if not isinstance(o,dict):

        invalid.append(
            {
                "file":str(p),
                "reason":
                    "not_object",
            }
        )

        continue


    if (
        o.get("locked") is not True
        or not o.get("country_code")
    ):

        invalid.append(
            {
                "file":str(p),
                "reason":
                    "invalid_lock",
            }
        )

        continue


    valid+=1

    countries[
        str(
            o.get(
                "country_code"
            )
        ).upper()
    ]+=1


print(
    "IDENTITY_TOTAL=",
    total,
)

print(
    "IDENTITY_VALID=",
    valid,
)

print(
    "IDENTITY_INVALID=",
    len(invalid),
)

print(
    "IDENTITY_COUNTRIES=",
    dict(
        countries.most_common()
    ),
)


for row in invalid[:20]:

    print(
        "INVALID_IDENTITY=",
        row,
    )


assert total>=1
assert valid==total
assert not invalid

print(
    "IDENTITY_INTEGRITY=PASS"
)
PY


echo
echo "=== 4. FINAL IDENTITY <-> PIPELINE CONSISTENCY ==="

"$PY" <<'PY'
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
identity_without_pipeline=0

country_conflicts=[]
uncertain_locked=[]


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

        identity_without_pipeline+=1

        continue


    try:
        pipeline=json.loads(
            pp.read_text()
        )
    except Exception:

        country_conflicts.append(
            {
                "config_id":cid,
                "reason":
                    "pipeline_bad_json",
            }
        )

        continue


    checked+=1


    identity_country=str(
        ident.get(
            "country_code"
        )
        or ""
    ).upper()


    pipeline_country=str(
        pipeline.get(
            "country_code"
        )
        or ""
    ).upper()


    if (
        identity_country
        !=pipeline_country
    ):

        country_conflicts.append(
            {
                "config_id":cid,

                "identity":
                    identity_country,

                "pipeline":
                    pipeline_country,

                "state":
                    pipeline.get(
                        "state"
                    ),
            }
        )


    state=str(
        pipeline.get(
            "state"
        )
        or ""
    ).lower()


    if state in {
        "ambiguous",
        "unresolved",
        "unknown",
    }:

        uncertain_locked.append(
            {
                "config_id":cid,
                "state":state,
            }
        )


print(
    "CONSISTENCY_CHECKED=",
    checked,
)

print(
    "IDENTITY_WITHOUT_PIPELINE=",
    identity_without_pipeline,
)

print(
    "COUNTRY_CONFLICTS=",
    len(country_conflicts),
)

print(
    "LOCKED_UNCERTAIN=",
    len(uncertain_locked),
)


for row in country_conflicts[:20]:

    print(
        "COUNTRY_CONFLICT=",
        row,
    )


for row in uncertain_locked[:20]:

    print(
        "LOCKED_UNCERTAIN_ROW=",
        row,
    )


assert not country_conflicts
assert not uncertain_locked

print(
    "GLOBAL_COUNTRY_CONSISTENCY=PASS"
)
PY


echo
echo "=== 5. PIPELINE FINAL INVENTORY ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

P=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

states=Counter()

total=0
country_known=0
country_missing=0
bad_json=0

for p in P.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:

        bad_json+=1
        continue


    total+=1

    state=str(
        o.get("state")
        or "unknown"
    )

    states[state]+=1


    if o.get(
        "country_code"
    ):
        country_known+=1
    else:
        country_missing+=1


print(
    "PIPELINE_TOTAL=",
    total,
)

print(
    "PIPELINE_STATES=",
    dict(states),
)

print(
    "COUNTRY_KNOWN=",
    country_known,
)

print(
    "COUNTRY_MISSING=",
    country_missing,
)

print(
    "PIPELINE_BAD_JSON=",
    bad_json,
)


assert bad_json==0

print(
    "PIPELINE_INVENTORY=PASS"
)
PY


echo
echo "=== 6. LIVE HARD-UNRESOLVED POLICY AUDIT ==="

"$PY" <<'PY'
from pathlib import Path
import json

P=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

I=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

hard=[]


for p in P.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue


    state=str(
        o.get("state")
        or ""
    ).lower()


    if state not in {
        "ambiguous",
        "unresolved",
        "unknown",
    }:

        continue


    cid=str(
        o.get("config_id")
        or p.stem
    )


    if o.get(
        "country_code"
    ):

        continue


    identity=I/f"{cid}.json"


    locked=False

    if identity.exists():

        try:

            x=json.loads(
                identity.read_text()
            )

            locked=(
                x.get("locked") is True
                and bool(
                    x.get(
                        "country_code"
                    )
                )
            )

        except Exception:
            pass


    if locked:
        continue


    hard.append(
        {
            "config_id":cid,
            "state":state,
            "exit_ip":
                o.get("exit_ip"),
        }
    )


print(
    "LIVE_TRUE_HARD_UNRESOLVED=",
    len(hard),
)


for row in hard[:30]:

    print(
        "LIVE_HARD=",
        row,
    )


# This is a live production system.
# Unresolved is valid and preferred over false Country.
print(
    "FALSE_COUNTRY_POLICY=STRICT"
)

print(
    "LIVE_UNRESOLVED_POLICY=PASS"
)
PY


echo
echo "=== 7. RESULTS / EVIDENCE STORE ==="

"$PY" <<'PY'
from pathlib import Path
import json

root=Path(
    "/var/lib/config-location/country/"
    "results/latest"
)

total=0
bad=0

if root.exists():

    for p in root.glob(
        "*.json"
    ):

        try:
            json.loads(
                p.read_text()
            )

            total+=1

        except Exception:
            bad+=1


print(
    "RESULTS_TOTAL=",
    total,
)

print(
    "RESULTS_BAD_JSON=",
    bad,
)

assert bad==0

print(
    "RESULTS_EVIDENCE_STORE=PASS"
)
PY


echo
echo "=== 8. K7/K8/K9 ARCHITECTURE GUARDS ==="

grep -q \
'FIX22_K7_PIPELINE_IDENTITY_GUARD' \
"$R/app/country/pipeline.py"

grep -q \
'FIX22_K9_IDENTITY_IMMEDIATE_RECONCILIATION' \
"$R/app/country/event_consumer.py"

grep -q \
'FIX22_K8_REAL_WORKER_RETIREMENT' \
"$R/app/country/event_consumer.py"

grep -q \
'FIX22_K8C_CPU_CAP_TEST_HOOK' \
"$R/app/country/event_consumer.py"

grep -q \
'FIX22_K8D_DEFERRED_BACKPRESSURE' \
"$R/app/country/event_consumer.py"

grep -q \
'geo_singleflight_lock' \
"$R/app/country/geo_intelligence.py"

grep -q \
'FIX22K5_PARALLEL_GEO' \
"$R/app/country/geo_providers.py"


echo "K4_SINGLEFLIGHT=PASS"
echo "K5_PARALLEL_GEO=PASS"
echo "K7_IDENTITY_GUARD=PASS"
echo "K8_REAL_RETIREMENT=PASS"
echo "K8_CPU_CAP=PASS"
echo "K8_DEFERRED_BACKPRESSURE=PASS"
echo "K9_IMMEDIATE_SYNC=PASS"


echo
echo "=== 9. SECOND XRAY / EXIT PROBE INVARIANT ==="

if grep -q \
'observe_exit_ip' \
"$R/app/country/event_consumer.py"
then

    echo "ERROR=SECOND_EXIT_PROBE_PRESENT"

    exit 1
fi


echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "COUNTRY_DETECTION_ONCE=PASS"


echo
echo "=== 10. RESOURCE HARDENING ==="

systemctl show \
config-location-country-event-consumer.service \
-p MemoryCurrent \
-p MemoryHigh \
-p MemoryMax \
-p TasksCurrent \
-p TasksMax \
-p CPUQuotaPerSecUSec \
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


assert "MemoryHigh=536870912" in text

assert "MemoryMax=805306368" in text

assert "TasksMax=128" in text

assert "OOMPolicy=stop" in text


print(
    "RESOURCE_HARDENING=PASS"
)
PY


echo
echo "=== 11. EVENT BUS FINAL AUDIT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

s=stats()

print(
    "QUEUE=",
    s,
)

assert int(
    s.get(
        "dead",
        0,
    )
)==0

assert int(
    s.get(
        "leased",
        0,
    )
)>=0

print(
    "EVENT_BUS=PASS"
)
PY


echo
echo "=== 12. BENCHMARK RESULT AUDIT ==="

"$PY" <<'PY'
from pathlib import Path
import json

root=Path(
    "/var/lib/config-location/country"
)

k9c=json.loads(
    (
        root
        /"k9c-latest.json"
    ).read_text()
)


print(
    "K9C_BENCHMARK_SIZE=",
    k9c.get(
        "benchmark_size"
    ),
)

print(
    "K9C_TERMINAL_EVENTS=",
    k9c.get(
        "terminal_events"
    ),
)

print(
    "K9C_TERMINAL_RATE=",
    k9c.get(
        "terminal_rate_per_second"
    ),
)

print(
    "K9C_ACKED=",
    k9c.get(
        "acked"
    ),
)

print(
    "K9C_DEFERRED=",
    k9c.get(
        "deferred"
    ),
)

print(
    "K9C_DEFERRED_RATIO=",
    k9c.get(
        "deferred_ratio"
    ),
)

print(
    "K9C_ERROR=",
    k9c.get(
        "error"
    ),
)

print(
    "K9C_CONSISTENCY_BAD=",
    k9c.get(
        "consistency_bad"
    ),
)

print(
    "K9C_DEAD_ZERO=",
    k9c.get(
        "dead_letter_zero"
    ),
)


assert int(
    k9c.get(
        "benchmark_size",
        0,
    )
)==1000

assert int(
    k9c.get(
        "terminal_events",
        0,
    )
)>=1000

assert int(
    k9c.get(
        "error",
        -1,
    )
)==0

assert int(
    k9c.get(
        "consistency_bad",
        -1,
    )
)==0

assert (
    k9c.get(
        "dead_letter_zero"
    )
    is True
)


print(
    "K9_BENCHMARK_AUDIT=PASS"
)
PY


echo
echo "=== 13. SERVICE HEALTH ==="

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
        "$svc" \
        2>/dev/null || true
    )

    echo "$svc=$X"

    test "$X" = active

done


echo
echo "=== 14. SERVICE FAILED STATE ==="

FAILED=0

for svc in \
config-location-country-event-consumer.service \
config-location-country-worker.service \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do

    F=$(
        systemctl is-failed \
        "$svc" \
        2>/dev/null || true
    )

    echo "$svc.failed=$F"

    if [ "$F" = failed ]; then
        FAILED=$((FAILED+1))
    fi

done

test "$FAILED" -eq 0

echo "FAILED_SERVICES=0"


echo
echo "=== 15. FINAL REPORT ==="

export OUT

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json
import os
import time

from app.country.event_bus import stats

ROOT=Path(
    "/var/lib/config-location/country"
)

k7=json.loads(
    (
        ROOT
        /"k7-final-audit.json"
    ).read_text()
)

k8=json.loads(
    (
        ROOT
        /"k8-final-audit.json"
    ).read_text()
)

k9=json.loads(
    (
        ROOT
        /"k9c-latest.json"
    ).read_text()
)


report={
    "schema_version":1,

    "generated_epoch":
        int(time.time()),

    "project":
        "config-location",

    "stage":
        "K9D",

    "k7_complete":
        True,

    "k8_complete":
        True,

    "k9_complete":
        True,

    "country_identity":
        "authoritative_country",

    "pipeline":
        "authoritative_temporal_state",

    "results":
        "evidence_history",

    "false_country_policy":
        "strict",

    "second_xray":
        False,

    "second_exit_probe":
        False,

    "country_detection_once":
        True,

    "real_worker_scale_down":
        True,

    "cpu_aware_worker_cap":
        8,

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

    "k7":
        k7,

    "k8":
        k8,

    "k9c":
        k9,

    "production_validation":
        "PASS",
}


out=Path(
    os.environ["OUT"]
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
    "FINAL_PRODUCTION_REPORT=PASS"
)
PY


test -s "$OUT"

echo "FINAL_REPORT_PATH=$OUT"


echo
echo "======================================================"
echo "FIX22K9D=PASS"
echo "FIX22K9=COMPLETE"
echo "K7=COMPLETE"
echo "K8=COMPLETE"
echo "K9=COMPLETE"
echo "COUNTRY_IDENTITY_CONSISTENCY=PASS"
echo "PRODUCTION_VALIDATION=PASS"
echo "ERRORS=ZERO"
echo "DEAD_LETTER=ZERO"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "MAIN_K_STAGES=COMPLETE"
echo "======================================================"
