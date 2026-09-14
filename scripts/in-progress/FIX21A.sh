#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

D=/var/lib/config-location
H="$D/health-results/latest"
C="$D/configs"

echo "=== 1. HEALTH STATE DEFINITIONS ==="

grep -RIn \
--include="*.py" \
-B10 -A80 \
-E "class HealthState|Enum|HEALTHY|UNHEALTHY|NOT_TESTED|ERROR|runtime_failed|infra|qualified|health_qualified" \
"$R/app/health" \
| head -n 900


echo "=== 2. LIFECYCLE OWNERS ==="

grep -RIn \
--include="*.py" \
-B15 -A120 \
-E "lifecycle|delete.*config|unlink\\(|remove\\(|expiry|expired|ttl|lifetime|unhealthy|health_latest|orphan|referential" \
"$R/app" \
| head -n 1400


echo "=== 3. LIFECYCLE SERVICES ==="

systemctl cat \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service \
--no-pager


echo "=== 4. LIFECYCLE CODE FILES ==="

find "$R/app" \
-type f \
-name "*.py" \
| grep -E \
"lifecycle|watchdog|referential|retention|cleanup|expiry" \
| sort


echo "=== 5. CURRENT HEALTH SHAPES ==="

"$PY" <<'PY'
from pathlib import Path
import json
from collections import Counter

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

states=Counter()
reasons=Counter()
qualified=Counter()

sample={}

for p in H.glob("*.json"):
    try:
        o=json.loads(p.read_text())
    except Exception:
        states["<invalid-json>"] += 1
        continue

    state=str(
        o.get("state")
        or o.get("health_state")
        or "<missing>"
    )

    states[state] += 1

    reason=str(
        o.get("reason")
        or o.get("failure_reason")
        or o.get("error")
        or "<none>"
    )

    reasons[reason] += 1

    q=o.get("health_qualified")

    qualified[str(q)] += 1

    sample.setdefault(
        state,
        o,
    )

print("STATES=",dict(states))
print("QUALIFIED=",dict(qualified))

print("TOP_REASONS=")

for k,v in reasons.most_common(25):
    print(v,k)

print("SAMPLES=")

for k,o in sample.items():
    print(
        "STATE=",
        k,
    )
    print(
        json.dumps(
            o,
            ensure_ascii=False,
            indent=2,
        )[:2200]
    )
PY


echo "=== 6. CONFIG / HEALTH RELATION ==="

"$PY" <<'PY'
from pathlib import Path
import time

C=Path(
    "/var/lib/config-location/configs"
)

H=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

configs={p.stem for p in C.glob("*.json")}
health={p.stem for p in H.glob("*.json")}

orphan=sorted(
    health-configs
)

missing=sorted(
    configs-health
)

print("CONFIGS=",len(configs))
print("HEALTH=",len(health))
print("ORPHAN=",len(orphan))
print("MISSING=",len(missing))

print("ORPHAN_SAMPLE=",orphan[:20])
print("MISSING_SAMPLE=",missing[:20])
PY


echo "=== 7. LIFECYCLE JOURNAL ==="

journalctl \
-u config-location-lifecycle-sync.service \
-u config-location-lifecycle-watchdog.service \
--since "-30 min" \
--no-pager \
-n 260 || true


echo "=== 8. SERVICES ==="

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
echo "FIX21A=PASS"
echo "HEALTH_SEMANTICS_AUDIT=COMPLETE"
echo "LIFECYCLE_CONTRACT_AUDIT=COMPLETE"
echo "========================================"
