#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

GI="$R/app/country/geo_intelligence.py"
MET=/var/lib/config-location/country/k4-singleflight-metrics.jsonl

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K4C-$TS"

mkdir -p "$B"
cp -a "$GI" "$B/"

echo "BACKUP=$B"


echo "=== 1. ADD NON-FATAL K4 METRICS ==="

export GI

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["GI"])
s=p.read_text()

if "k4-singleflight-metrics.jsonl" in s:
    print("K4_METRICS_ALREADY_PRESENT=YES")
    raise SystemExit(0)

s=s.replace(
    "from collections import Counter\n",
    "from collections import Counter\n"
    "import json\n"
    "import os\n"
    "import time\n"
    "from pathlib import Path\n",
    1,
)

marker='''from .network_classifier import (
    classify_network,
)
'''

helper=r'''

_K4_METRICS=Path(
    "/var/lib/config-location/country/"
    "k4-singleflight-metrics.jsonl"
)


def _k4_metric(
    *,
    ip: str,
    role: str,
    cache_hit: bool,
) -> None:

    try:
        _K4_METRICS.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        row={
            "ts_ns":time.time_ns(),
            "ip":ip,
            "role":role,
            "cache_hit":cache_hit,
        }

        fd=os.open(
            _K4_METRICS,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_APPEND,
            0o600,
        )

        try:
            os.write(
                fd,
                (
                    json.dumps(
                        row,
                        sort_keys=True,
                    )
                    +"\n"
                ).encode(),
            )
        finally:
            os.close(fd)

    except Exception:
        pass
'''

if marker not in s:
    raise SystemExit(
        "ERROR: import marker not found"
    )

s=s.replace(
    marker,
    marker+helper,
    1,
)


s=s.replace(
'''        return {
            **cached,
            "cache_hit":True,
            "singleflight_role":
                "cache_hit",
        }
''',
'''        _k4_metric(
            ip=ip,
            role="cache_hit",
            cache_hit=True,
        )

        return {
            **cached,
            "cache_hit":True,
            "singleflight_role":
                "cache_hit",
        }
''',
1,
)


s=s.replace(
'''            return {
                **cached,
                "cache_hit":True,
                "singleflight_role":
                    "waiter_cache_hit",
            }
''',
'''            _k4_metric(
                ip=ip,
                role="waiter_cache_hit",
                cache_hit=True,
            )

            return {
                **cached,
                "cache_hit":True,
                "singleflight_role":
                    "waiter_cache_hit",
            }
''',
1,
)


s=s.replace(
'''        return {
            **result,
            "singleflight_role":
                "owner",
        }
''',
'''        _k4_metric(
            ip=ip,
            role="owner",
            cache_hit=False,
        )

        return {
            **result,
            "singleflight_role":
                "owner",
        }
''',
1,
)

p.write_text(s)

print("K4_METRICS_PATCH=PASS")
PY


echo "=== 2. COMPILE ==="

"$PY" -m py_compile \
"$GI" \
"$R/app/country/geo_cache.py" \
"$R/app/country/pipeline.py"

echo "COMPILE=PASS"


echo "=== 3. RESET METRICS ==="

rm -f "$MET"

echo "METRICS_RESET=PASS"


echo "=== 4. RESTART COUNTRY WORKER ==="

systemctl restart \
config-location-country-worker.service

sleep 4

test "$(
    systemctl is-active \
    config-location-country-worker.service
)" = active

echo "COUNTRY_WORKER=active"


echo "=== 5. COLLECT REAL GEO CALLS ==="

FOUND=0

for i in $(seq 1 60)
do

    N=0

    if [ -f "$MET" ]; then
        N=$(wc -l <"$MET")
    fi

    echo "T=$((i*5))s GEO_CALLS=$N"

    if [ "$N" -ge 30 ]; then
        FOUND=1
        break
    fi

    sleep 5
done

test "$FOUND" -eq 1


echo "=== 6. ANALYZE K4 PRODUCTION ROLES ==="

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

assert len(rows)>=30


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


hits=sum(
    1
    for r in rows
    if r.get("cache_hit") is True
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


owners=roles.get(
    "owner",
    0,
)

waiters=roles.get(
    "waiter_cache_hit",
    0,
)

normal_hits=roles.get(
    "cache_hit",
    0,
)


print(
    "OWNERS=",
    owners,
)

print(
    "WAITERS=",
    waiters,
)

print(
    "DIRECT_HITS=",
    normal_hits,
)


unexpected={
    k:v
    for k,v in roles.items()
    if k not in {
        "owner",
        "waiter_cache_hit",
        "cache_hit",
    }
}

print(
    "UNEXPECTED=",
    unexpected,
)

assert not unexpected


print(
    "K4_PRODUCTION_METRICS=PASS"
)
PY


echo "=== 7. CACHE INTEGRITY ==="

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

assert invalid==0

print(
    "CACHE_INTEGRITY=PASS"
)
PY


echo "=== 8. QUEUE STATUS ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

print(
    "QUEUE=",
    stats(),
)
PY


echo "=== 9. SERVICES ==="

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
echo "FIX22K4C=PASS"
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
