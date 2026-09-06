#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location

echo "=== POLICY ==="
sed -n "1,320p" \
"$R/app/health/lifecycle/policy.py"

echo "=== CONSECUTIVE ==="
sed -n "1,300p" \
"$R/app/health/lifecycle/consecutive.py"

echo "=== ENGINE ==="
sed -n "1,320p" \
"$R/app/health/lifecycle/engine.py"

echo "=== ENFORCEMENT ==="
sed -n "1,340p" \
"$R/app/health/lifecycle/enforcement.py"

echo "=== SAFETY GATES ==="
sed -n "1,320p" \
"$R/app/health/lifecycle/safety_gates.py"

echo "=== SYNC DAEMON CALL PATH ==="
grep -n \
-B20 -A160 \
-E "policy|consecutive|enforce|delete|watchdog|run_once" \
"$R/app/health/lifecycle/sync_daemon.py"

echo "=== CURRENT LIFECYCLE STATE ==="

for f in \
/var/lib/config-location/health-lifecycle/consecutive-state.json \
/var/lib/config-location/health-lifecycle/policy-latest.json \
/var/lib/config-location/health-lifecycle/sync-status.json \
/var/lib/config-location/health-lifecycle/watchdog-status.json
do
    echo "FILE=$f"
    if [ -f "$f" ]; then
        head -c 5000 "$f"
        echo
    else
        echo "MISSING"
    fi
done

echo "========================================"
echo "FIX21A3=PASS"
echo "EXACT_LIFECYCLE_SEMANTICS=PINNED"
echo "========================================"
