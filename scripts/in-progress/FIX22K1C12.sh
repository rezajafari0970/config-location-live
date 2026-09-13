#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
SVC=config-location-health-adaptive.service

echo "=== 1. ACTIVE SERVICE CONTRACT ==="

systemctl cat "$SVC"

echo
echo "=== 2. ACTIVE PROCESS ==="

PID=$(systemctl show \
    "$SVC" \
    -p MainPID \
    --value)

echo "MAIN_PID=$PID"

test "$PID" -gt 0

echo "CMDLINE="
tr '\0' ' ' \
<"/proc/$PID/cmdline"

echo

echo "EXE=$(readlink -f /proc/$PID/exe)"
echo "CWD=$(readlink -f /proc/$PID/cwd)"

echo
echo "=== 3. PROCESS TREE ==="

ps -ef --forest \
| grep -A20 -B5 "$PID" \
| grep -v grep || true

echo
echo "=== 4. SERVICE ENTRYPOINT SOURCE ==="

EXEC=$(
    systemctl show \
    "$SVC" \
    -p ExecStart \
    --value
)

echo "EXECSTART=$EXEC"

echo
echo "=== 5. ACTIVE ADAPTIVE FILES ==="

grep -RIn \
--include='*.py' \
-B30 -A100 \
-E \
'continuous_adaptive_runner|adaptive_runner|production_scheduler|ResultStore|JsonHealthResultStore|result_store.save|run_health_job|run_job_with_retry' \
"$R/app/health/core" \
| head -n 2400 || true

echo
echo "=== 6. WHO IMPORTS PRODUCTION_SCHEDULER ==="

grep -RIn \
--include='*.py' \
-E \
'production_scheduler|run_production_scheduler_once' \
"$R/app" || true

echo
echo "=== 7. WHO SAVES HEALTH RESULTS ==="

grep -RIn \
--include='*.py' \
-B20 -A60 \
-E \
'\.save\(.*result|result_store\.save|JsonHealthResultStore\(' \
"$R/app/health" \
| head -n 1800 || true

echo
echo "=== 8. ACTIVE FILE MTIME PROOF ==="

python3 <<'PY'
from pathlib import Path
import time

root=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

now=time.time()

rows=[]

for p in root.glob("*.json"):

    age=now-p.stat().st_mtime

    if age <= 120:
        rows.append(
            (
                age,
                p.name,
            )
        )

rows.sort()

print(
    "RESULTS_LAST_120S=",
    len(rows),
)

for age,name in rows[:20]:
    print(
        round(age,2),
        name,
    )
PY

echo
echo "=== 9. PATCH FILE EXECUTION QUESTION ==="

grep -RIn \
'FIX22K1 RESULT_STORE_EVENT' \
"$R/app" || true

echo
echo "=== 10. SERVICES ==="

for svc in \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-fetcher.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done

echo
echo "========================================"
echo "FIX22K1C12=PASS"
echo "MODE=ACTIVE-HEALTH-CALLGRAPH"
echo "PRODUCTION_CHANGED=NO"
echo "========================================"
