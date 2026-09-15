#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

D=/var/lib/config-location
C="$D/configs"
H="$D/health-results/latest"

echo "=== 1. STORE HEALTH ==="

PYTHONPATH="$R" \
"$PY" -m app.integrity.run_store_health >/dev/null

"$PY" <<'PY'
import json
from pathlib import Path

p=Path(
    "/var/lib/config-location/"
    "integrity/store-health-latest.json"
)

c=json.loads(
    p.read_text()
)["counts"]

print("CONFIGS=",c["configs"])
print("HEALTH=",c["health_latest"])
print(
    "WITHOUT_HEALTH=",
    c["configs_without_health"],
)
print(
    "ORPHAN_HEALTH=",
    c["orphan_health"],
)
PY


echo "=== 2. EXACT MISSING HEALTH SET ==="

"$PY" <<'PY'
from pathlib import Path
import json
from collections import Counter

C=Path(
    "/var/lib/config-location/configs"
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

configs={
    p.stem:p
    for p in C.glob("*.json")
}

health={
    p.stem
    for p in H.glob("*.json")
}

missing=[
    cid
    for cid in configs
    if cid not in health
]

print(
    "MISSING_TOTAL=",
    len(missing),
)

types=Counter()
ages=[]

for cid in missing:

    p=configs[cid]

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        continue

    t=(
        o.get("config_type")
        or o.get("type")
        or o.get("protocol")
        or "unknown"
    )

    types[str(t)] += 1

    ages.append(
        (
            p.stat().st_mtime,
            cid,
            t,
        )
    )

print("MISSING_BY_TYPE=")

for k,v in types.most_common():
    print(k,v)

print("OLDEST_MISSING_SAMPLE=")

for _,cid,t in sorted(ages)[:30]:
    print(cid,t)

print("NEWEST_MISSING_SAMPLE=")

for _,cid,t in sorted(
    ages,
    reverse=True,
)[:30]:
    print(cid,t)
PY


echo "=== 3. QUEUE / LEASE / STATE FILES ==="

find "$D" \
-maxdepth 4 \
-type f \
\( \
-name "*queue*" \
-o -name "*lease*" \
-o -name "*adaptive*" \
-o -name "*scheduler*" \
-o -name "*state*" \
\) \
-printf "%p %s bytes\n" \
| sort \
| head -n 250


echo "=== 4. COVERAGE-RELATED CODE ==="

grep -RIn \
--include="*.py" \
-B10 -A45 \
-E "without_health|missing_health|health_latest|lease|requeue|selected_target|attempted|starvation|priority|oldest|queue|not_tested|retry_after|backoff" \
"$R/app/health/core" \
| head -n 1200


echo "=== 5. CONTINUOUS RUNNER SELECTION ==="

grep -n \
-B30 -A320 \
-E "selected_target|job_map|queue|lease|requeue|attempted|persist_queue|active\\[" \
"$R/app/health/core/continuous_adaptive_runner.py" \
| head -n 1200


echo "=== 6. PRODUCTION ADAPTIVE ==="

sed -n "1,360p" \
"$R/app/health/core/production_adaptive.py"


echo "=== 7. CURRENT SERVICE ==="

systemctl show \
config-location-health-adaptive.service \
-p ActiveState \
-p SubState \
-p Result \
-p MainPID \
-p TasksCurrent \
--no-pager


echo "=== 8. CURRENT HEALTH JOURNAL ==="

journalctl \
-u config-location-health-adaptive.service \
--since "-20 min" \
--no-pager \
-n 220 || true


echo "========================================"
echo "FIX20.9A=PASS"
echo "HEALTH_COVERAGE_GAP_AUDIT=COMPLETE"
echo "========================================"
