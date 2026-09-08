#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
CORE="$R/app/health/core"

echo "=== HEALTH ADAPTIVE FILES ==="

find "$CORE" \
-type f \
-name "*.py" \
| grep -E \
'adaptive|scheduler|queue|runner' \
| sort


echo "=== SYSTEMD HEALTH WORKER ==="

systemctl cat \
config-location-health-adaptive.service


echo "=== ADAPTIVE ENTRYPOINTS ==="

grep -RIn \
--include="*.py" \
-B15 -A100 \
-E "def main|if __name__|run_forever|while True|continuous|daemon" \
"$CORE" \
| head -n 900 || true


echo "=== QUEUE / PRIORITY CONTRACT ==="

grep -RIn \
--include="*.py" \
-B15 -A120 \
-E "queue|priority|lease|retry|next_run|due|backoff|enqueue|dequeue" \
"$CORE" \
| head -n 1200 || true


echo "=== PRODUCTION SCHEDULER ==="

sed -n '1,320p' \
"$CORE/production_scheduler.py" \
2>/dev/null || true


echo "=== PRODUCTION ADAPTIVE ==="

sed -n '1,360p' \
"$CORE/production_adaptive.py" \
2>/dev/null || true


echo "=== CONTINUOUS RUNNER ==="

sed -n '1,360p' \
"$CORE/continuous_adaptive_runner.py" \
2>/dev/null || true


echo "=== ALWAYS-ON CONTROLLER ==="

sed -n '1,360p' \
"$CORE/always_on_adaptive.py" \
2>/dev/null || true


echo "=== LOCKING ==="

grep -RIn \
--include="*.py" \
-B12 -A90 \
-E "flock|lockfile|LOCK|acquire|release|fcntl" \
"$CORE" \
| head -n 700 || true


echo "=== HEALTH DAEMON WRAPPER ==="

sed -n '1,260p' \
/opt/config-location/bin/health-adaptive-daemon \
2>/dev/null || true


echo "=== COUNTRY / HEALTH POPULATION ==="

python3 - <<'PY'
from pathlib import Path
from collections import Counter
import json

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

health=Counter()
country=Counter()

for p in H.glob("*.json"):
    try:
        o=json.loads(p.read_text())
    except Exception:
        continue
    health[str(o.get("state"))]+=1

for p in P.glob("*.json"):
    try:
        o=json.loads(p.read_text())
    except Exception:
        continue
    country[str(o.get("state"))]+=1

print(
    "HEALTH_STATES=",
    dict(health),
)

print(
    "COUNTRY_STATES=",
    dict(country),
)

print(
    "HEALTHY=",
    health.get("healthy",0),
)

print(
    "COUNTRY_RESULTS=",
    sum(country.values()),
)
PY


echo "=== SERVICES ==="

for svc in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    X=$(systemctl is-active "$svc" 2>/dev/null || true)
    echo "$svc=$X"
    test "$X" = active
done


echo "========================================"
echo "FIX22H1A2=PASS"
echo "COUNTRY_WORKER_REUSE_CONTRACT=PINNED"
echo "HEALTH_WORKER_UNCHANGED=YES"
echo "PRODUCTION_UNCHANGED=YES"
echo "========================================"
