#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

echo "=== SERVICE EXECSTART ==="

systemctl show \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service \
-p ExecStart \
-p ActiveState \
-p SubState \
--no-pager


echo "=== LIFECYCLE FILES ==="

find "$R/app" \
-type f \
-name "*.py" \
| grep -E \
"lifecycle|watchdog|referential" \
| sort


echo "=== DELETE OWNERS ==="

grep -RIn \
--include="*.py" \
-E "unlink\\(|os\\.remove|shutil\\.rmtree|delete_config|remove_config" \
"$R/app" \
| grep -E \
"lifecycle|health|integrity" \
| head -n 120


echo "=== HEALTH MODEL ==="

grep -RIn \
--include="*.py" \
-B5 -A45 \
"^class HealthState" \
"$R/app/health" \
| head -n 100


echo "=== LIFECYCLE DECISIONS ==="

grep -RIn \
--include="*.py" \
-B12 -A65 \
-E "HealthState\\.|state.*healthy|state.*unhealthy|failure_streak|consecutive|lifetime|expired|expires|ttl" \
"$R/app" \
| grep -E \
"lifecycle|watchdog|health" \
| head -n 450


echo "=== CURRENT STATE COUNTS ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

states=Counter()
decisions=Counter()

for p in H.glob("*.json"):
    try:
        o=json.loads(p.read_text())
    except Exception:
        states["INVALID_JSON"] += 1
        continue

    states[str(
        o.get("state","<missing>")
    )] += 1

    md=o.get("metadata") or {}
    d=md.get("health_decision") or {}

    decisions[
        (
            str(d.get("healthy")),
            str(d.get("reason")),
        )
    ] += 1

print("STATES=",dict(states))

print("DECISIONS_TOP=")

for k,v in decisions.most_common(15):
    print(v,k)
PY


echo "=== ORPHAN AGE ==="

"$PY" <<'PY'
from pathlib import Path
import time

C=Path("/var/lib/config-location/configs")
H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

configs={p.stem for p in C.glob("*.json")}
now=time.time()

rows=[]

for p in H.glob("*.json"):
    if p.stem not in configs:
        rows.append(
            (
                now-p.stat().st_mtime,
                p.stem,
            )
        )

rows.sort(reverse=True)

print("ORPHAN_COUNT=",len(rows))

if rows:
    print(
        "OLDEST_ORPHAN_SECONDS=",
        int(rows[0][0]),
    )

    print(
        "GT30S=",
        sum(x[0]>=30 for x in rows),
    )

    print(
        "GT60S=",
        sum(x[0]>=60 for x in rows),
    )

    print(
        "GT300S=",
        sum(x[0]>=300 for x in rows),
    )
PY


echo "=== FIX21A2 PASS ==="
