#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
D=/var/lib/config-location
C="$D/configs"
H="$D/health-results/latest"

echo "=== COVERAGE ==="

"$PY" <<'PY'
from pathlib import Path
import json
import time
from collections import Counter

C=Path("/var/lib/config-location/configs")
H=Path("/var/lib/config-location/health-results/latest")

configs={p.stem:p for p in C.glob("*.json")}
health={p.stem for p in H.glob("*.json")}

missing=[
    (cid,p)
    for cid,p in configs.items()
    if cid not in health
]

now=time.time()

print("CONFIGS=",len(configs))
print("HEALTH=",len(health))
print("MISSING=",len(missing))

types=Counter()
ages=Counter()

rows=[]

for cid,p in missing:

    try:
        o=json.loads(p.read_text())
    except Exception:
        types["<invalid-json>"] += 1
        continue

    t=str(
        o.get("config_type")
        or o.get("type")
        or o.get("protocol")
        or "<unknown>"
    )

    types[t]+=1

    age=now-p.stat().st_mtime

    if age < 60:
        ages["<1m"]+=1
    elif age < 300:
        ages["1-5m"]+=1
    elif age < 900:
        ages["5-15m"]+=1
    elif age < 3600:
        ages["15-60m"]+=1
    else:
        ages[">1h"]+=1

    rows.append(
        (
            p.stat().st_mtime,
            cid,
            t,
            int(age),
        )
    )

print("BY_TYPE=",dict(types))
print("BY_AGE=",dict(ages))

print("OLDEST_20=")

for _,cid,t,age in sorted(rows)[:20]:
    print(cid,t,age)
PY


echo "=== ADAPTIVE STATE FILES ==="

find "$D" \
-maxdepth 4 \
-type f \
\( \
-name "*queue*.json" \
-o -name "*lease*.json" \
-o -name "*adaptive*.json" \
-o -name "*scheduler*.json" \
\) \
-printf "%p %s\n" \
| sort \
| head -n 80


echo "=== SELECTION CONTRACT ==="

grep -n \
-B12 -A45 \
-E "selected_target|attempted|requeue_lease|lease|queue|job_map" \
"$R/app/health/core/continuous_adaptive_runner.py" \
| head -n 380


echo "=== PRODUCTION LIMIT ==="

grep -n \
-B10 -A35 \
-E "max_jobs|run_continuous_adaptive_test" \
"$R/app/health/core/production_adaptive.py" \
| head -n 180


echo "=== SERVICE ==="

systemctl show \
config-location-health-adaptive.service \
-p ActiveState \
-p SubState \
-p Result \
-p MainPID \
--no-pager


echo "=== FIX20.9A2 PASS ==="
