#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
Q="$R/app/health/core/adaptive_live_queue.py"
S=/var/lib/config-location/health-adaptive/queue-state.json

echo "=== RECONCILE ==="
grep -n -A100 "^def reconcile" "$Q"

echo "=== LEASE_NEXT ==="
grep -n -A100 "^def lease_next" "$Q"

echo "=== FINISH ==="
grep -n -A80 "^def finish_lease" "$Q"

echo "=== REQUEUE ==="
grep -n -A80 "^def requeue_lease" "$Q"

echo "=== STATE SUMMARY ==="

"$PY" <<'PY'
import json
from pathlib import Path

o=json.loads(
    Path(
        "/var/lib/config-location/"
        "health-adaptive/queue-state.json"
    ).read_text()
)

for k,v in o.items():
    if isinstance(v,(list,dict)):
        print(k,type(v).__name__,len(v))
    else:
        print(k,type(v).__name__,v)

for key in (
    "pending",
    "queue",
    "ready",
    "leased",
    "completed",
):
    v=o.get(key)

    if isinstance(v,list):
        print(
            key+"_FIRST10=",
            v[:10],
        )
        print(
            key+"_LAST10=",
            v[-10:],
        )
PY

echo "=== CURRENT COVERAGE ==="

"$PY" <<'PY'
from pathlib import Path
import time

C=Path("/var/lib/config-location/configs")
H=Path("/var/lib/config-location/health-results/latest")

health={p.stem for p in H.glob("*.json")}
now=time.time()

ages=sorted(
    (
        now-p.stat().st_mtime
        for p in C.glob("*.json")
        if p.stem not in health
    ),
    reverse=True,
)

print("MISSING=",len(ages))
print(
    "OLDEST_SECONDS=",
    int(ages[0]) if ages else 0,
)
print(
    "OLDER_5M=",
    sum(x>=300 for x in ages),
)
print(
    "OLDER_15M=",
    sum(x>=900 for x in ages),
)
print(
    "OLDER_30M=",
    sum(x>=1800 for x in ages),
)
PY

echo "=== FIX20.9B2 PASS ==="
