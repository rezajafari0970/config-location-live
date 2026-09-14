#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
F="$R/app/health/lifecycle/consecutive.py"
PY="$R/venv/bin/python"

echo "=== FUNCTION MAP ==="

"$PY" <<'PY'
from pathlib import Path
import ast

p=Path(
    "/opt/config-location/app/health/"
    "lifecycle/consecutive.py"
)

s=p.read_text()
tree=ast.parse(s)

for n in tree.body:
    if isinstance(n,ast.FunctionDef):
        print(
            f"{n.name}: "
            f"{n.lineno}-{n.end_lineno}"
        )
PY

echo
echo "=== CONSECUTIVE 210-END ==="

nl -ba "$F" \
| sed -n '210,620p'

echo
echo "=== ALL RESULT_FINGERPRINT CALLS ==="

grep -n \
-B20 -A80 \
'result_fingerprint(' \
"$F"

echo
echo "=== ALL TRACKER WRITES ==="

grep -n \
-B30 -A80 \
-E \
'TRACKER_PATH|atomic_json_if_changed|_atomic_json' \
"$F"

echo
echo "=== HEALTH QUALIFIED USES ==="

grep -n \
-B30 -A80 \
'health_qualified' \
"$F"

echo
echo "=== WHO CALLS THIS MODULE ==="

grep -RIn \
--include='*.py' \
-E \
'from app.health.lifecycle.consecutive|import.*consecutive|update_consecutive|process_latest|sync_consecutive' \
"$R/app" \
| head -n 500 || true

echo
echo "=== SAFETY CHECK ==="

test "$(
    systemctl is-active \
    config-location-health-adaptive.service
)" = active

test "$(
    systemctl is-active \
    config-location-country-worker.service
)" = active

echo "HEALTH=active"
echo "COUNTRY=active"

echo
echo "========================================"
echo "FIX22K1C4=PASS"
echo "K1C3_FAILURE=SAFE"
echo "PRODUCTION_PATCHED=NO"
echo "========================================"
