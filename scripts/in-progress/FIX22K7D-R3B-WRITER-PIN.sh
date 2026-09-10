#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
W="$R/app/country/worker.py"

echo "=== 1. WORKER WRITE SITE A ==="
nl -ba "$W" | sed -n '540,660p'

echo
echo "=== 2. WORKER WRITE SITE B ==="
nl -ba "$W" | sed -n '840,970p'

echo
echo "=== 3. PROCESS_COUNTRY CALLS ==="
grep -n -B8 -A25 \
'process_country' \
"$W"

echo
echo "=== 4. COUNTRY_ROOT WRITES ==="
grep -n -B15 -A25 \
'atomic_json' \
"$W"

echo
echo "=== 5. PIPELINE DIRECT SAVE CONTRACT ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect
from app.country import pipeline

for name in (
    "process_country",
    "save_result",
    "_save_result",
):

    obj=getattr(
        pipeline,
        name,
        None,
    )

    if obj is None:
        continue

    print()
    print(
        "FUNCTION=",
        name,
        inspect.signature(obj),
    )

    try:
        print(
            inspect.getsource(obj)
        )
    except Exception as exc:
        print(
            "SOURCE_ERROR=",
            exc,
        )
PY

echo
echo "=== 6. CURRENT OWNERSHIP SUMMARY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

P=Path(
    "/var/lib/config-location/country/"
    "pipeline/latest"
)

R=Path(
    "/var/lib/config-location/country/"
    "results/latest"
)

I=Path(
    "/var/lib/config-location/country/"
    "country-identity"
)

print(
    "PIPELINE_FILES=",
    sum(1 for _ in P.glob("*.json")),
)

print(
    "RESULT_FILES=",
    sum(1 for _ in R.glob("*.json")),
)

print(
    "IDENTITY_FILES=",
    sum(1 for _ in I.glob("*.json")),
)

# Count the exact conflict that R4 must solve.
conflicts=0
examples=[]

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
        pipe=json.loads(
            pp.read_text()
        )
    except Exception:
        continue

    if (
        pipe.get("country_code")
        !=ident.get("country_code")
        or str(
            pipe.get("state")
            or ""
        ) in {
            "ambiguous",
            "unresolved",
        }
    ):
        conflicts+=1

        if len(examples)<20:
            examples.append(
                {
                    "config_id":cid,
                    "identity_country":
                        ident.get(
                            "country_code"
                        ),
                    "pipeline_country":
                        pipe.get(
                            "country_code"
                        ),
                    "pipeline_state":
                        pipe.get(
                            "state"
                        ),
                }
            )

print(
    "LOCKED_IDENTITY_PIPELINE_CONFLICTS=",
    conflicts,
)

for row in examples:
    print(
        "CONFLICT=",
        row,
    )
PY

echo
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

    X=$(
        systemctl is-active \
        "$svc" 2>/dev/null || true
    )

    echo "$svc=$X"
    test "$X" = active
done

echo
echo "======================================================"
echo "FIX22K7D_R3B=PASS"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=FIX22K7D-R4-DUAL-STORE-RECONCILIATION"
echo "======================================================"
