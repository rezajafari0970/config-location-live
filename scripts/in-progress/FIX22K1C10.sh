#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

echo "=== RESULTSTORE DEFINITIONS ==="

grep -RIn \
--include='*.py' \
-B30 -A180 \
-E \
'class ResultStore|def save\(|ResultStore\(' \
"$R/app/health" \
| head -n 1600

echo
echo "=== RESULTSTORE IMPORT IN SCHEDULER ==="

grep -n \
-B20 -A30 \
-E \
'ResultStore|result_store' \
"$R/app/health/core/production_scheduler.py" \
| head -n 350

echo
echo "=== HEALTHRESULT DEFINITION ==="

grep -RIn \
--include='*.py' \
-B20 -A220 \
-E \
'class HealthResult|def to_dict|asdict' \
"$R/app/health" \
| head -n 1600

echo
echo "=== OBJECT VS PERSISTED SAMPLE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import ast

root=Path(
    "/opt/config-location/app/health"
)

for p in root.rglob("*.py"):

    try:
        s=p.read_text()
        tree=ast.parse(s)
    except Exception:
        continue

    for n in ast.walk(tree):

        if not isinstance(
            n,
            ast.ClassDef,
        ):
            continue

        if n.name in {
            "ResultStore",
            "HealthResult",
        }:

            print()
            print(
                "FILE=",
                p,
            )

            print(
                "CLASS=",
                n.name,
            )

            print(
                "LINES=",
                n.lineno,
                n.end_lineno,
            )

            print(
                ast.get_source_segment(
                    s,
                    n,
                )
            )
PY

echo
echo "=== SERVICES ==="

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
echo "FIX22K1C10=PASS"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=CANONICAL_RESULT_EVENT"
echo "========================================"
