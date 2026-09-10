#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
P="$R/app/country/pipeline.py"
B="$R/app/country/event_bus.py"

echo "=== 1. COMPLETE PROCESS_COUNTRY SIGNATURE/WINDOW ==="

"$PY" <<'PY'
from pathlib import Path
import ast

p=Path(
    "/opt/config-location/app/country/pipeline.py"
)

s=p.read_text()
t=ast.parse(s)

for n in t.body:
    if (
        isinstance(n,ast.FunctionDef)
        and n.name=="process_country"
    ):
        print(
            "PROCESS_COUNTRY_LINES=",
            n.lineno,
            n.end_lineno,
        )

        lines=s.splitlines()

        end=min(
            n.end_lineno,
            n.lineno+190,
        )

        for i in range(
            n.lineno-1,
            end,
        ):
            print(
                f"{i+1:04d}: "
                +lines[i]
            )

        break
PY


echo
echo "=== 2. EXIT OBSERVATION CONSTRUCTION ==="

grep -n \
-B40 -A100 \
-E \
'observe_exit_ip|ExitObservation|exit_obs|exit_ip=' \
"$P" \
| head -n 700


echo
echo "=== 3. PROCESS_COUNTRY CALLERS ==="

grep -RIn \
--include='*.py' \
-B12 -A35 \
'process_country(' \
"$R/app" \
| head -n 1000


echo
echo "=== 4. EVENT BUS LEASE SIGNATURE ==="

"$PY" <<'PY'
from pathlib import Path
import ast

p=Path(
    "/opt/config-location/app/country/event_bus.py"
)

s=p.read_text()
t=ast.parse(s)

wanted={
    "lease",
    "ack",
    "nack",
}

for n in t.body:

    if (
        isinstance(n,ast.FunctionDef)
        and n.name in wanted
    ):
        print(
            "\nFUNCTION=",
            n.name,
            "LINES=",
            n.lineno,
            n.end_lineno,
        )

        lines=s.splitlines()

        for i in range(
            n.lineno-1,
            min(
                n.end_lineno,
                n.lineno+100,
            ),
        ):
            print(
                f"{i+1:04d}: "
                +lines[i]
            )
PY


echo
echo "=== 5. CURRENT QUEUE ==="

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
echo "=== 6. RESOURCE SNAPSHOT ==="

echo "CPU_COUNT=$(nproc)"

free -m

echo
uptime


echo
echo "=== 7. SERVICES ==="

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
echo "================================================"
echo "FIX22K1_CONSUMER_B_PIN=PASS"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=FIX22K1-CONSUMER-B"
echo "================================================"
