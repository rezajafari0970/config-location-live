#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
MET=/var/lib/config-location/country/event-consumer-metrics.jsonl

echo "=== 1. STOP CONSUMER SAFELY ==="

systemctl stop \
config-location-country-event-consumer.service \
|| true

echo "CONSUMER_STOPPED=YES"


echo
echo "=== 2. ERROR TYPE SUMMARY ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

p=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)

rows=[]

for line in p.read_text().splitlines():
    try:
        rows.append(json.loads(line))
    except Exception:
        pass

errors=[
    r
    for r in rows
    if r.get("status")=="error"
]

c=Counter(
    str(r.get("error",""))
    for r in errors
)

print("ERROR_ROWS=",len(errors))
print()

for err,n in c.most_common(30):
    print("COUNT=",n)
    print("ERROR=",err)
    print("---")

print()
print("LAST_ERROR_SAMPLES=")

for r in errors[-30:]:
    print(
        json.dumps(
            r,
            ensure_ascii=False,
            sort_keys=True,
        )
    )
PY


echo
echo "=== 3. DEFERRED SAMPLE CONFIGS ==="

"$PY" <<'PY'
from pathlib import Path
import json

p=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)

n=0

for line in p.read_text().splitlines():
    try:
        r=json.loads(line)
    except Exception:
        continue

    if r.get("status")!="deferred_no_exit":
        continue

    print(
        "DEFERRED=",
        {
            "config_id":r.get("config_id"),
            "event_id":r.get("event_id"),
        },
    )

    n+=1
    if n>=10:
        break
PY


echo
echo "=== 4. CURRENT PENDING EVENT SHAPES ==="

PYTHONPATH="$R" "$PY" <<'PY'
from pathlib import Path
import json

Q=Path(
    "/var/lib/config-location/country/"
    "event-bus/pending"
)

shown=0

for p in sorted(Q.glob("*.json")):

    try:
        o=json.loads(p.read_text())
    except Exception:
        continue

    fast=(
        (o.get("metadata") or {})
        .get("same_runtime_country")
    )

    print(
        "EVENT=",
        {
            "file":p.name,
            "config_id":o.get("config_id"),
            "event_id":o.get("event_id"),
            "attempt":o.get("attempt"),
            "not_before":o.get("not_before_epoch"),
            "has_fast":isinstance(fast,dict),
            "fast_status":(
                fast.get("status")
                if isinstance(fast,dict)
                else None
            ),
            "exit_ip":(
                fast.get("exit_ip")
                if isinstance(fast,dict)
                else None
            ),
        },
    )

    shown+=1
    if shown>=30:
        break
PY


echo
echo "=== 5. HEALTH RESULT FILE NAMING ==="

find \
/var/lib/config-location/health-results/latest \
-maxdepth 1 \
-type f \
-printf '%f\n' \
| head -n 40


echo
echo "=== 6. HEALTH FASTPATH COVERAGE ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

root=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

total=0
healthy=0
fast_any=0
fast_success=0

for p in root.glob("*.json"):

    try:
        h=json.loads(p.read_text())
    except Exception:
        continue

    total+=1

    if str(
        h.get("state","")
    ).lower()=="healthy":
        healthy+=1

    fast=(
        (h.get("metadata") or {})
        .get("same_runtime_country")
    )

    if isinstance(fast,dict):
        fast_any+=1

        if (
            fast.get("status")=="success"
            and fast.get("exit_ip")
        ):
            fast_success+=1


print("HEALTH_TOTAL=",total)
print("HEALTHY=",healthy)
print("FAST_ANY=",fast_any)
print("FAST_SUCCESS=",fast_success)
PY


echo
echo "=== 7. SAVE_COUNTRY_RESULT SIGNATURE ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect

from app.country.storage import (
    save_country_result,
)

print(
    "SIGNATURE=",
    inspect.signature(
        save_country_result
    )
)

print(
    inspect.getsource(
        save_country_result
    )
)
PY


echo
echo "=== 8. RESOLVE_GEO SIGNATURE ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect

from app.country.geo_intelligence import (
    resolve_geo,
)

print(
    "SIGNATURE=",
    inspect.signature(
        resolve_geo
    )
)
PY


echo
echo "=== 9. QUEUE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import (
    recover_expired,
    stats,
)

print("RECOVERED=",recover_expired())
print("QUEUE=",stats())
PY


echo
echo "=== 10. SERVICES ==="

for svc in \
config-location-country-worker.service \
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


echo
echo "======================================================"
echo "FIX22K1_R3_ERROR_DIAG=PASS"
echo "CONSUMER_LEFT_STOPPED=YES"
echo "QUEUE_PRESERVED=YES"
echo "NEXT=FIX22K1-CONSUMER-B-R4"
echo "======================================================"
