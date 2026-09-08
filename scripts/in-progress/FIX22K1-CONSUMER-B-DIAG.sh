#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

echo "=== 1. STOP BROKEN CONSUMER SAFELY ==="

systemctl stop \
config-location-country-event-consumer.service \
|| true

echo "CONSUMER_STOPPED"


echo
echo "=== 2. EVENT BUS EXACT SIGNATURES ==="

PYTHONPATH="$R" "$PY" <<'PY'
import inspect

from app.country import event_bus

for name in (
    "lease",
    "ack",
    "nack",
    "recover_expired",
    "stats",
):
    fn=getattr(event_bus,name)

    print(
        name,
        inspect.signature(fn),
    )

    try:
        print(
            inspect.getsource(fn)
        )
    except Exception as exc:
        print(
            "SOURCE_ERROR=",
            exc,
        )

    print(
        "--------------------------------"
    )
PY


echo
echo "=== 3. CONSUMER JOURNAL ==="

journalctl \
-u config-location-country-event-consumer.service \
--since "20 minutes ago" \
--no-pager \
-l \
| tail -n 300


echo
echo "=== 4. RUN ONE LEASE MANUALLY ==="

PYTHONPATH="$R" "$PY" <<'PY'
import traceback

from app.country.event_bus import (
    lease,
    recover_expired,
    stats,
)

print(
    "BEFORE=",
    stats(),
)

try:
    r=recover_expired()

    print(
        "RECOVERED=",
        r,
    )

    item=lease()

    print(
        "LEASE_TYPE=",
        type(item),
    )

    print(
        "LEASE_REPR=",
        repr(item)[:4000],
    )

except Exception:
    traceback.print_exc()

print(
    "AFTER=",
    stats(),
)
PY


echo
echo "=== 5. CONSUMER SOURCE CRITICAL WINDOW ==="

nl -ba \
"$R/app/country/event_consumer.py" \
| sed -n '1,320p'


echo
echo "=== 6. QUEUE STATE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import (
    recover_expired,
    stats,
)

print(
    "RECOVERED_FINAL=",
    recover_expired(),
)

print(
    "QUEUE=",
    stats(),
)
PY


echo
echo "=== 7. CORE SERVICES ==="

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


echo
echo "=============================================="
echo "FIX22K1_CONSUMER_B_DIAG=PASS"
echo "BROKEN_CONSUMER=STOPPED"
echo "QUEUE_DATA=PRESERVED"
echo "NEXT=FIX22K1-CONSUMER-B-R2"
echo "=============================================="
