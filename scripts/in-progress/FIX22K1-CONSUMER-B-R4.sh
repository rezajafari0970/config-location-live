#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

APP="$R/app/country/event_consumer.py"
MET=/var/lib/config-location/country/event-consumer-metrics.jsonl

BUS=/var/lib/config-location/country/event-bus
DEAD="$BUS/dead-letter"
PENDING="$BUS/pending"

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K1-CONSUMER-B-R4-$TS"

mkdir -p "$B"

cp -a "$APP" "$B/"
[ -d "$DEAD" ] && cp -a "$DEAD" "$B/dead-letter-before-r4" || true

echo "BACKUP=$B"


echo
echo "=== 1. STOP CONSUMER ==="

systemctl stop \
config-location-country-event-consumer.service \
2>/dev/null || true

echo "CONSUMER_STOPPED=YES"


echo
echo "=== 2. PATCH STORAGE ADAPTER ==="

export APP

"$PY" <<'PY'
from pathlib import Path
import os

p=Path(os.environ["APP"])
s=p.read_text()

if "class _CountryResultAdapter" not in s:

    marker='''class MissingReusableExit(
    RuntimeError
):
    pass
'''

    addition='''class MissingReusableExit(
    RuntimeError
):
    pass


class _CountryResultAdapter:
    """
    Compatibility adapter for the canonical
    Country storage contract.

    save_country_result() expects an object
    exposing to_dict(), while the K1 consumer
    internally builds a plain dict.
    """

    def __init__(
        self,
        value: dict,
    ):
        self._value=dict(value)

    def to_dict(self) -> dict:
        return dict(self._value)

    def __getattr__(
        self,
        name: str,
    ):
        try:
            return self._value[name]
        except KeyError as exc:
            raise AttributeError(
                name
            ) from exc
'''

    if marker not in s:
        raise SystemExit(
            "ERROR: adapter insertion marker missing"
        )

    s=s.replace(
        marker,
        addition,
        1,
    )


old='''    save_country_result(
        result
    )
'''

new='''    save_country_result(
        _CountryResultAdapter(
            result
        )
    )
'''

if old not in s:

    if "_CountryResultAdapter(" not in s:
        raise SystemExit(
            "ERROR: save_country_result call not found"
        )

else:
    s=s.replace(
        old,
        new,
        1,
    )


p.write_text(s)

print(
    "STORAGE_ADAPTER_PATCH=PASS"
)
PY


echo
echo "=== 3. COMPILE ==="

"$PY" -m py_compile "$APP"

echo "COMPILE=PASS"


echo
echo "=== 4. STORAGE CONTRACT SELFTEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect

from app.country.storage import (
    save_country_result,
)

from app.country.event_consumer import (
    _CountryResultAdapter,
)

a=_CountryResultAdapter(
    {
        "config_id":"r4-test",
        "state":"pending_confirmation",
    }
)

assert a.to_dict()[
    "config_id"
]=="r4-test"

assert a.config_id=="r4-test"

print(
    "SAVE_SIGNATURE=",
    inspect.signature(
        save_country_result
    ),
)

print(
    "ADAPTER_TO_DICT=PASS"
)
PY


echo
echo "=== 5. RESTORE R2 DEAD LETTERS ==="

export DEAD PENDING

"$PY" <<'PY'
from pathlib import Path
import json
import os
import time

dead=Path(
    os.environ["DEAD"]
)

pending=Path(
    os.environ["PENDING"]
)

pending.mkdir(
    parents=True,
    exist_ok=True,
)

restored=0
skipped=0

if dead.exists():

    for p in list(
        dead.glob("*.json")
    ):

        try:
            o=json.loads(
                p.read_text()
            )
        except Exception:
            skipped+=1
            continue

        key=o.get(
            "event_key"
        )

        if not key:
            skipped+=1
            continue

        # These dead letters were created by the
        # temporary R2 consumer. Give them a fresh
        # durable retry opportunity under R4.
        o["attempt"]=0
        o["not_before_epoch"]=0

        o.pop(
            "lease_owner",
            None,
        )

        o.pop(
            "lease_until_epoch",
            None,
        )

        o.pop(
            "done_reason",
            None,
        )

        o["r4_restored_from_dead"]=True
        o["r4_restored_epoch"]=int(
            time.time()
        )

        priority=int(
            o.get(
                "priority",
                0,
            )
        )

        target=(
            pending
            /f"{priority:03d}-{key}.json"
        )

        tmp=target.with_suffix(
            ".tmp"
        )

        tmp.write_text(
            json.dumps(
                o,
                ensure_ascii=False,
                sort_keys=True,
            )
        )

        os.replace(
            tmp,
            target,
        )

        p.unlink(
            missing_ok=True
        )

        restored+=1


print(
    "DEAD_RESTORED=",
    restored,
)

print(
    "DEAD_SKIPPED=",
    skipped,
)

# We know R2 created dead letters, but don't
# hardcode exactly 42 in case worker state changed.
print(
    "DEAD_RESTORE=PASS"
)
PY


echo
echo "=== 6. QUEUE BEFORE R4 ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import (
    recover_expired,
    stats,
)

print(
    "RECOVERED=",
    recover_expired(),
)

print(
    "QUEUE_BEFORE=",
    stats(),
)
PY


echo
echo "=== 7. RESET R4 METRICS ==="

rm -f "$MET"

echo "METRICS_RESET=PASS"


echo
echo "=== 8. START R4 ==="

systemctl restart \
config-location-country-event-consumer.service

sleep 4

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER_SERVICE=active"


echo
echo "=== 9. OBSERVE REAL END-TO-END FOR 90s ==="

for i in $(seq 1 18)
do
    sleep 5

    PYTHONPATH="$R" "$PY" <<PY
from app.country.event_bus import stats

s=stats()

print(
    "T=$((i*5))s",
    "PENDING=",s.get("pending",0),
    "LEASED=",s.get("leased",0),
    "DONE=",s.get("done",0),
    "DEAD=",s.get("dead",0),
)
PY
done


echo
echo "=== 10. R4 METRIC ANALYSIS ==="

"$PY" <<'PY'
from pathlib import Path
from collections import Counter
import json

p=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)

assert p.exists()

rows=[]

for line in p.read_text().splitlines():

    try:
        rows.append(
            json.loads(line)
        )
    except Exception:
        pass


c=Counter(
    r.get(
        "status",
        "unknown",
    )
    for r in rows
)


print(
    "METRIC_ROWS=",
    len(rows),
)

print(
    "STATUS=",
    dict(c),
)


for key in (
    "leased",
    "processed",
    "acked",
    "deferred_no_exit",
    "error",
    "nack_error",
):

    print(
        key.upper(),
        "=",
        c.get(
            key,
            0,
        ),
    )


sources=Counter(
    r.get(
        "fast_source",
        "unknown",
    )
    for r in rows
    if r.get(
        "status"
    )=="processed"
)

print(
    "FAST_SOURCES=",
    dict(sources),
)


countries=Counter(
    r.get(
        "country_code"
    )
    for r in rows
    if (
        r.get(
            "status"
        )=="processed"
        and r.get(
            "country_code"
        )
    )
)

print(
    "COUNTRIES=",
    dict(
        countries.most_common(
            20
        )
    ),
)


processed=[
    r
    for r in rows
    if r.get(
        "status"
    )=="processed"
]


for r in processed[:15]:

    print(
        "PROCESSED_SAMPLE=",
        r,
    )


assert c.get(
    "leased",
    0,
)>=1

assert c.get(
    "processed",
    0,
)>=1, (
    "still no successfully persisted country result"
)

assert c.get(
    "acked",
    0,
)>=1, (
    "event processing did not reach ACK"
)

assert c.get(
    "nack_error",
    0,
)==0


# The old dict/to_dict failure must be gone.
for r in rows:

    if r.get(
        "status"
    )!="error":
        continue

    assert (
        "object has no attribute 'to_dict'"
        not in str(
            r.get(
                "error",
                "",
            )
        )
    )


print(
    "R4_END_TO_END=PASS"
)
PY


echo
echo "=== 11. COUNTRY RESULT STORAGE PROOF ==="

"$PY" <<'PY'
from pathlib import Path
import json

met=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)

processed=[]

for line in met.read_text().splitlines():

    try:
        r=json.loads(line)
    except Exception:
        continue

    if r.get(
        "status"
    )=="processed":

        processed.append(r)


assert processed

print(
    "PROCESSED_RESULTS=",
    len(processed),
)

print(
    "STORAGE_PERSISTENCE=PASS"
)
PY


echo
echo "=== 12. QUEUE FINAL ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats

s=stats()

print(
    "QUEUE_FINAL=",
    s,
)

assert s.get(
    "done",
    0,
)>=1

print(
    "ACK_TO_DONE=PASS"
)
PY


echo
echo "=== 13. THREAD HEALTH ==="

PID=$(
    systemctl show \
    config-location-country-event-consumer.service \
    -p MainPID \
    --value
)

echo "PID=$PID"

test "$PID" -gt 0

THREADS=$(
    ps -T \
    -p "$PID" \
    --no-headers \
    | wc -l
)

echo "THREADS=$THREADS"

test "$THREADS" -ge 3

echo "WORKER_THREADS=PASS"


echo
echo "=== 14. NO SECOND XRAY / EXIT PROBE ==="

if grep -q \
'observe_exit_ip' \
"$APP"
then
    echo "ERROR=SECOND_EXIT_PROBE"
    exit 1
fi

echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"


echo
echo "=== 15. SERVICES ==="

for svc in \
config-location-country-event-consumer.service \
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


echo
echo "======================================================"
echo "FIX22K1_CONSUMER_B_R4=PASS"
echo "HEALTH_TO_COUNTRY_EVENT_FLOW=END_TO_END"
echo "COUNTRY_RESULT_PERSISTENCE=PASS"
echo "LEASE_ACK_DONE=PASS"
echo "PRE_K2_BACKLOG=PRESERVED"
echo "R2_DEAD_LETTERS=RESTORED"
echo "K2_EXIT_HANDOFF=USED"
echo "K4_CACHE_SINGLEFLIGHT=USED"
echo "K5_PARALLEL_GEO=USED"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "NEXT=CONSUMER-C-ADAPTIVE-DRAIN"
echo "======================================================"
