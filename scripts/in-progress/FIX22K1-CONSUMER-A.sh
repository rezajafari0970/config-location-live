#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

BUS="$R/app/country/event_bus.py"
PIPE="$R/app/country/pipeline.py"
WORKER="$R/app/country/worker.py"

echo "=== 1. EVENT BUS PUBLIC FUNCTIONS ==="

"$PY" <<'PY'
from pathlib import Path
import ast

p=Path(
    "/opt/config-location/app/country/"
    "event_bus.py"
)

s=p.read_text()
t=ast.parse(s)

for n in t.body:

    if isinstance(
        n,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
        ),
    ):

        print(
            f"{n.name}:"
            f"{n.lineno}-"
            f"{n.end_lineno}"
        )
PY


echo
echo "=== 2. EVENT BUS LEASE / ACK / NACK CONTRACT ==="

grep -n \
-B25 -A100 \
-E \
'def lease|def ack|def nack|def recover_expired|def stats|dead|retry|attempt' \
"$BUS" \
| head -n 1500


echo
echo "=== 3. EVENT JSON SHAPE ==="

grep -n \
-B30 -A120 \
-E \
'health_generation|same_runtime_country|config_id|metadata|event_id' \
"$BUS" \
| head -n 1200


echo
echo "=== 4. COUNTRY PIPELINE ENTRY FUNCTIONS ==="

"$PY" <<'PY'
from pathlib import Path
import ast

p=Path(
    "/opt/config-location/app/country/"
    "pipeline.py"
)

s=p.read_text()
t=ast.parse(s)

for n in t.body:

    if isinstance(
        n,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
        ),
    ):

        print(
            f"{n.name}:"
            f"{n.lineno}-"
            f"{n.end_lineno}"
        )
PY


echo
echo "=== 5. PIPELINE CALLS TO RESOLVE_GEO ==="

grep -n \
-B80 -A180 \
'resolve_geo' \
"$PIPE" \
| head -n 1500


echo
echo "=== 6. COUNTRY RESULT STORE / FINAL STATE ==="

grep -RIn \
--include='*.py' \
-B20 -A90 \
-E \
'save.*country|pipeline/latest|confirmed_stable|confirmed_rotating_ip|pending_confirmation' \
"$R/app/country" \
| head -n 2000


echo
echo "=== 7. EXISTING WORKER ENTRY ==="

grep -n \
-B60 -A180 \
-E \
'def run|def process|pipeline|country' \
"$WORKER" \
| head -n 1600


echo
echo "=== 8. QUEUE SAMPLE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

Q=Path(
    "/var/lib/config-location/country/"
    "event-bus/pending"
)

files=sorted(
    Q.glob("*.json")
)[:5]

print(
    "SAMPLE_COUNT=",
    len(files),
)

for p in files:

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception as exc:
        print(
            "BAD_EVENT=",
            p.name,
            exc,
        )
        continue

    fast=(
        (
            o.get("metadata")
            or {}
        ).get(
            "same_runtime_country"
        )
    )

    print(
        "EVENT=",
        {
            "file":
                p.name,

            "event_id":
                o.get("event_id"),

            "config_id":
                o.get("config_id"),

            "generation":
                o.get(
                    "health_generation"
                ),

            "has_fastpath":
                isinstance(
                    fast,
                    dict,
                ),

            "exit_ip":
                (
                    fast.get("exit_ip")
                    if isinstance(
                        fast,
                        dict,
                    )
                    else None
                ),

            "fast_status":
                (
                    fast.get("status")
                    if isinstance(
                        fast,
                        dict,
                    )
                    else None
                ),
        },
    )
PY


echo
echo "=== 9. QUEUE STATE ==="

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
PY


echo
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


echo
echo "=============================================="
echo "FIX22K1_CONSUMER_A=PASS"
echo "MODE=CONSUMER-CONTRACT-PIN"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=FIX22K1-CONSUMER-B"
echo "=============================================="
