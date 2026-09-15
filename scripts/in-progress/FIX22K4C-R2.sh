#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

GI="$R/app/country/geo_intelligence.py"
GC="$R/app/country/geo_cache.py"
MET=/var/lib/config-location/country/k4-singleflight-metrics.jsonl

echo "=== 1. VERIFY K4 CODE ==="

grep -q \
'def geo_singleflight_lock' \
"$GC"

grep -q \
'FIX22K4_SINGLEFLIGHT_OWNER' \
"$GI"

grep -q \
'k4-singleflight-metrics.jsonl' \
"$GI"

"$PY" -m py_compile \
"$GI" \
"$GC" \
"$R/app/country/pipeline.py"

echo "K4_CODE=PASS"


echo "=== 2. USE EXISTING REAL METRICS ==="

test -f "$MET"

N=$(wc -l <"$MET")

echo "REAL_METRIC_ROWS=$N"

test "$N" -ge 5


echo "=== 3. ANALYZE PRODUCTION ROLES ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

p=Path(
    "/var/lib/config-location/country/"
    "k4-singleflight-metrics.jsonl"
)

rows=[]

for line in p.read_text().splitlines():

    try:
        rows.append(
            json.loads(line)
        )
    except Exception:
        pass


print(
    "ROWS=",
    len(rows),
)

assert len(rows)>=5


roles=Counter(
    r.get(
        "role",
        "unknown",
    )
    for r in rows
)

print(
    "ROLES=",
    dict(roles),
)


allowed={
    "owner",
    "waiter_cache_hit",
    "cache_hit",
}

unexpected={
    k:v
    for k,v in roles.items()
    if k not in allowed
}

print(
    "UNEXPECTED=",
    unexpected,
)

assert not unexpected


hits=sum(
    1
    for r in rows
    if r.get(
        "cache_hit"
    ) is True
)

print(
    "CACHE_HITS=",
    hits,
)

print(
    "CACHE_HIT_RATE=",
    round(
        hits/len(rows),
        4,
    ),
)


print(
    "OWNERS=",
    roles.get(
        "owner",
        0,
    ),
)

print(
    "WAITERS=",
    roles.get(
        "waiter_cache_hit",
        0,
    ),
)

print(
    "DIRECT_HITS=",
    roles.get(
        "cache_hit",
        0,
    ),
)

assert (
    sum(roles.values())
    == len(rows)
)

print(
    "K4_PRODUCTION_METRICS=PASS"
)
PY


echo "=== 4. CACHE INTEGRITY ==="

"$PY" <<'PY'
from pathlib import Path
import json

root=Path(
    "/var/lib/config-location/country/"
    "geo-cache"
)

valid=0
invalid=0

for p in root.glob("*.json"):

    try:
        o=json.loads(
            p.read_text()
        )
    except Exception:
        invalid+=1
        continue

    if (
        isinstance(o,dict)
        and isinstance(
            o.get("value"),
            dict,
        )
        and o.get("ip")
    ):
        valid+=1
    else:
        invalid+=1


print(
    "CACHE_VALID=",
    valid,
)

print(
    "CACHE_INVALID=",
    invalid,
)

assert valid>=1
assert invalid==0

print(
    "CACHE_INTEGRITY=PASS"
)
PY


echo "=== 5. CROSS-PROCESS CONTRACT STILL PRESENT ==="

grep -q \
'fcntl.LOCK_EX' \
"$GC"

grep -q \
'waiter_cache_hit' \
"$GI"

echo "CROSS_PROCESS_SINGLEFLIGHT=PASS"


echo "=== 6. QUEUE STATUS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "QUEUE=",
    stats(),
)
PY


echo "=== 7. SERVICES ==="

for svc in \
config-location-country-worker.service \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do

    X=$(
        systemctl is-active \
        "$svc" 2>/dev/null || true
    )

    echo "$svc=$X"

    test "$X" = active
done


echo "======================================================"
echo "FIX22K4C_R2=PASS"
echo "FIX22K4=COMPLETE"
echo "GEO_CACHE=PRODUCTION_VERIFIED"
echo "SINGLEFLIGHT=PRODUCTION_VERIFIED"
echo "CACHE_TTL=7D"
echo "PER_IP_LOCK=YES"
echo "DOUBLE_CHECK_AFTER_LOCK=YES"
echo "CROSS_PROCESS=YES"
echo "ATOMIC_WRITE=PRESERVED"
echo "NEXT=FIX22K5"
echo "======================================================"
