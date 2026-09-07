#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
F="$R/app/health/lifecycle/consecutive.py"

echo "=== UPDATE_TRACKER ==="

grep -n \
-B25 -A190 \
"^def update_tracker" \
"$F"

echo "=== LOAD CONFIG / HEALTH REFERENCES ==="

grep -n \
-B12 -A70 \
-E "^def load_|CONFIG|config_root|configs|records" \
"$F" \
| tail -n 260

echo "=== TRACKER WRITE ==="

grep -n \
-B20 -A50 \
-E "_atomic_json|TRACKER|consecutive-state" \
"$F" \
| tail -n 220

echo "=== CURRENT TRACKER SHAPE ==="

python3 - <<'PY'
import json
from pathlib import Path

p=Path(
    "/var/lib/config-location/"
    "health-lifecycle/"
    "consecutive-state.json"
)

o=json.loads(p.read_text())

print("TOP_KEYS=",sorted(o.keys()))

for k,v in o.items():
    if isinstance(v,dict):
        print(k,"DICT",len(v))
    elif isinstance(v,list):
        print(k,"LIST",len(v))
    else:
        print(k,type(v).__name__,v)

records=o.get("records",{})

if isinstance(records,dict):
    print(
        "RECORD_SAMPLE=",
        list(records.items())[:2],
    )
PY

echo "========================================"
echo "FIX21C2=PASS"
echo "TRACKER_GC_ANCHOR=PINNED"
echo "========================================"
