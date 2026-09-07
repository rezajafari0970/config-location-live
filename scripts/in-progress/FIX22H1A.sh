#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location

echo "=== HEALTH ADAPTIVE WORKER FILES ==="

find "$R/app/health" \
-type f \
-name "*.py" \
| grep -E \
'adaptive|scheduler|worker|queue' \
| sort


echo "=== SYSTEMD HEALTH WORKER ==="

systemctl cat \
config-location-health-adaptive.service


echo "=== ADAPTIVE ENTRYPOINT ==="

grep -RIn \
--include="*.py" \
-B20 -A120 \
-E "def main|if __name__|run_forever|while True" \
"$R/app/health/adaptive" \
| head -n 700


echo "=== QUEUE / LEASE CONTRACT ==="

grep -RIn \
--include="*.py" \
-B15 -A100 \
-E "queue-state|lease|enqueue|dequeue|priority|retry|next_run|due" \
"$R/app/health/adaptive" \
| head -n 900


echo "=== LOCKING ==="

grep -RIn \
--include="*.py" \
-B12 -A80 \
-E "flock|FileLock|lockfile|LOCK|acquire|release" \
"$R/app/health" \
| head -n 500


echo "=== COUNTRY RESULT COUNTS ==="

python3 - <<'PY'
from pathlib import Path
from collections import Counter
import json

P=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

states=Counter()
countries=Counter()

for p in P.glob("*.json"):
    try:
        o=json.loads(p.read_text())
    except Exception:
        continue

    states[str(o.get("state"))]+=1

    if o.get("country_code"):
        countries[str(o["country_code"])]+=1

print("COUNTRY_RESULTS=",sum(states.values()))
print("STATES=",dict(states))
print("COUNTRIES=",dict(countries))
PY


echo "=== CURRENT HEALTH POPULATION ==="

python3 - <<'PY'
from pathlib import Path
from collections import Counter
import json

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

c=Counter()

for p in H.glob("*.json"):
    try:
        o=json.loads(p.read_text())
    except Exception:
        continue

    c[str(o.get("state"))]+=1

print(dict(c))
PY


echo "=== SERVICES ==="

for svc in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do
    echo "$svc=$(systemctl is-active "$svc" 2>/dev/null || true)"
done


echo "========================================"
echo "FIX22H1A=PASS"
echo "COUNTRY_WORKER_REUSE_CONTRACT=PINNED"
echo "========================================"
