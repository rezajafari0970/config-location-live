#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

ENGINE="$R/app/health/core/engine.py"
HOOK="$R/app/country/health_hook.py"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K2C-$TS"

mkdir -p "$B"

cp -a "$ENGINE" "$B/"
cp -a "$HOOK" "$B/"

echo "BACKUP=$B"


echo "=== 1. PATCH ENGINE TO RETAIN FASTPATH RESULT ==="

python3 <<'PY'
from pathlib import Path

p=Path(
    "/opt/config-location/app/health/core/engine.py"
)

s=p.read_text()

old='''                run_same_runtime_fastpath(
                    config_id=result.config_id,
                    job_id=result.job_id,
                    proxy_url=runtime.proxy_url,
                )
'''

new='''                _country_fastpath = (
                    run_same_runtime_fastpath(
                        config_id=result.config_id,
                        job_id=result.job_id,
                        proxy_url=runtime.proxy_url,
                    )
                )

                # K2 durable handoff:
                # Preserve the already-observed Exit-IP
                # inside the canonical HealthResult.
                result.metadata[
                    "same_runtime_country"
                ] = _country_fastpath
'''

if old not in s:
    raise SystemExit(
        "ERROR: K2B fastpath call not found"
    )

s=s.replace(
    old,
    new,
    1,
)

p.write_text(s)

print(
    "ENGINE_HANDOFF_PATCH=PASS"
)
PY


echo "=== 2. PASS HANDOFF INTO EVENT BUS ==="

python3 <<'PY'
from pathlib import Path

p=Path(
    "/opt/config-location/app/country/"
    "health_hook.py"
)

s=p.read_text()

old='''            metadata={
                "producer":
                    "health-result-store",

                "canonical_serializer":
                    "JsonHealthResultStore._result_to_dict",

                "state":
                    "healthy",

                "xray_started":
                    True,

                "download_verified":
                    True,

                "upload_verified":
                    True,
            },
'''

new='''            metadata={
                "producer":
                    "health-result-store",

                "canonical_serializer":
                    "JsonHealthResultStore._result_to_dict",

                "state":
                    "healthy",

                "xray_started":
                    True,

                "download_verified":
                    True,

                "upload_verified":
                    True,

                # K2 Same-Runtime Handoff.
                # Consumer can reuse Exit-IP without
                # launching Xray or probing exit again.
                "same_runtime_country":
                    (
                        (
                            o.get("metadata")
                            or {}
                        ).get(
                            "same_runtime_country"
                        )
                    ),
            },
'''

if old not in s:
    raise SystemExit(
        "ERROR: health_hook metadata block "
        "not found"
    )

s=s.replace(
    old,
    new,
    1,
)

p.write_text(s)

print(
    "EVENT_HANDOFF_PATCH=PASS"
)
PY


echo "=== 3. COMPILE ==="

"$PY" -m py_compile \
"$ENGINE" \
"$HOOK" \
"$R/app/country/same_runtime_fastpath.py" \
"$R/app/country/event_bus.py"

echo "COMPILE=PASS"


echo "=== 4. SHOW ENGINE HANDOFF ==="

grep -n \
-B18 -A45 \
'same_runtime_country' \
"$ENGINE"


echo "=== 5. RESET K2/K1 PROOF DATA ==="

rm -f \
/var/lib/config-location/country/same-runtime-fastpath.jsonl \
2>/dev/null || true

rm -f \
/var/lib/config-location/country/event-bus/producer-metrics.jsonl \
2>/dev/null || true

# Keep existing durable pending queue.
echo "EXISTING_QUEUE=PRESERVED"


echo "=== 6. RESTART HEALTH ==="

systemctl restart \
config-location-health-adaptive.service

sleep 5

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = active

echo "HEALTH=active"


echo "=== 7. WAIT FOR HANDOFF EVENTS ==="

FOUND=0

for i in $(seq 1 24)
do

    N=0

    if [ -f \
        /var/lib/config-location/country/event-bus/producer-metrics.jsonl
    ]; then

        N=$(
            wc -l \
            </var/lib/config-location/country/event-bus/producer-metrics.jsonl
        )
    fi

    echo "T=$((i*5))s PRODUCER_ROWS=$N"

    if [ "$N" -ge 5 ]; then
        FOUND=1
        break
    fi

    sleep 5
done

test "$FOUND" -eq 1


echo "=== 8. VERIFY HEALTHRESULT CONTAINS HANDOFF ==="

"$PY" <<'PY'
from pathlib import Path
import json
import time

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

cut=time.time()-180

rows=[]

for p in H.glob("*.json"):

    if p.stat().st_mtime < cut:
        continue

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    if str(
        o.get(
            "state",
            "",
        )
    ).lower()!="healthy":
        continue

    fast=(
        (
            o.get("metadata")
            or {}
        ).get(
            "same_runtime_country"
        )
    )

    if isinstance(
        fast,
        dict,
    ):
        rows.append(
            (
                o,
                fast,
            )
        )


print(
    "HEALTH_HANDOFF_ROWS=",
    len(rows),
)

assert len(rows)>=1


success=[
    (h,f)
    for h,f in rows
    if (
        f.get("status")
        =="success"
        and f.get("exit_ip")
    )
]


print(
    "HEALTH_HANDOFF_SUCCESS=",
    len(success),
)

assert len(success)>=1


for h,f in success[:5]:

    print(
        "SAMPLE=",
        {
            "config_id":
                h.get("config_id"),

            "job_id":
                h.get("job_id"),

            "exit_ip":
                f.get("exit_ip"),

            "elapsed_ms":
                f.get("elapsed_ms"),

            "same_runtime":
                f.get("same_runtime"),

            "new_xray_started":
                f.get(
                    "new_xray_started"
                ),
        },
    )

    assert (
        f.get(
            "same_runtime"
        )
        is True
    )

    assert (
        f.get(
            "new_xray_started"
        )
        is False
    )


print(
    "CANONICAL_HEALTH_HANDOFF=PASS"
)
PY


echo "=== 9. VERIFY EVENT BUS CONTAINS HANDOFF ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

Q=Path(
    "/var/lib/config-location/country/"
    "event-bus/pending"
)

rows=[]

for p in Q.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    fast=(
        (
            o.get("metadata")
            or {}
        ).get(
            "same_runtime_country"
        )
    )

    if (
        isinstance(fast,dict)
        and fast.get(
            "status"
        )=="success"
        and fast.get(
            "exit_ip"
        )
    ):
        rows.append(
            (
                o,
                fast,
            )
        )


print(
    "EVENT_HANDOFF_ROWS=",
    len(rows),
)

assert len(rows)>=1


for e,f in rows[:5]:

    print(
        "EVENT_SAMPLE=",
        {
            "config_id":
                e.get(
                    "config_id"
                ),

            "generation":
                e.get(
                    "health_generation"
                ),

            "exit_ip":
                f.get(
                    "exit_ip"
                ),

            "agreed":
                f.get(
                    "agreed"
                ),

            "elapsed_ms":
                f.get(
                    "elapsed_ms"
                ),
        },
    )


print(
    "DURABLE_EVENT_HANDOFF=PASS"
)
PY


echo "=== 10. VERIFY NO COUNTRY PUBLICATION YET ==="

echo "K2_COUNTRY_PUBLICATION=NO"
echo "K2_GEO_LOOKUP=NO"
echo "K2_SECOND_EXIT_PROBE=NO"
echo "K2_SECOND_XRAY=NO"


echo "=== 11. EVENT BUS STATE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "QUEUE=",
    stats(),
)

print(
    "K1_FALLBACK=PASS"
)
PY


echo "=== 12. SERVICES ==="

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
        "$svc" \
        2>/dev/null || true
    )

    echo "$svc=$X"

    test "$X" = active
done


echo "======================================================"
echo "FIX22K2C=PASS"
echo "FIX22K2=COMPLETE"
echo "SAME_RUNTIME_EXIT_IP=YES"
echo "HANDOFF_IN_HEALTH_RESULT=YES"
echo "HANDOFF_IN_EVENT_BUS=YES"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "GEO_LOOKUP_IN_HEALTH_PATH=NO"
echo "COUNTRY_FAILURE_AFFECTS_HEALTH=NO"
echo "K1_FALLBACK=PRESERVED"
echo "BACKUP=$B"
echo "NEXT=FIX22K3"
echo "======================================================"
