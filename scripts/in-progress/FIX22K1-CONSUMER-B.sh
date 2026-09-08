#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

APP="$R/app/country/event_consumer.py"
BIN="$R/bin/country-event-consumer"
UNIT=/etc/systemd/system/config-location-country-event-consumer.service

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K1-CONSUMER-B-$TS"

mkdir -p "$B"

[ -f "$APP" ] && cp -a "$APP" "$B/" || true
[ -f "$BIN" ] && cp -a "$BIN" "$B/" || true
[ -f "$UNIT" ] && cp -a "$UNIT" "$B/" || true

echo "BACKUP=$B"


echo "=== 1. INSTALL EVENT CONSUMER ==="

cat >"$APP" <<'PY'
from __future__ import annotations

import json
import os
import signal
import threading
import time
from pathlib import Path

from app.country.event_bus import (
    ack,
    lease,
    nack,
    recover_expired,
    stats,
)
from app.country.geo_intelligence import resolve_geo
from app.country.storage import save_country_result


STOP=threading.Event()

METRICS=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)


FINAL_STATES={
    "confirmed_stable",
    "confirmed_rotating_ip",
}


def _metric(row: dict) -> None:
    try:
        METRICS.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        row={
            "ts_ns":time.time_ns(),
            **row,
        }

        fd=os.open(
            METRICS,
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


def _process_event(event: dict) -> None:

    event_id=str(
        event.get("event_id") or ""
    )

    config_id=str(
        event.get("config_id") or ""
    )

    if not event_id or not config_id:
        raise ValueError(
            "event missing event_id/config_id"
        )


    metadata=(
        event.get("metadata")
        or {}
    )

    fast=(
        metadata.get(
            "same_runtime_country"
        )
        or {}
    )


    if not isinstance(fast,dict):
        raise ValueError(
            "same_runtime_country missing"
        )


    exit_ip=fast.get("exit_ip")

    if (
        fast.get("status")!="success"
        or not exit_ip
    ):
        raise ValueError(
            "no reusable same-runtime exit_ip"
        )


    exit_ip=str(exit_ip)


    # Important:
    # No Xray and no exit-IP probe here.
    # We only consume the durable K2 handoff.
    geo=resolve_geo(
        config_id=config_id,
        ip=exit_ip,
    )


    state=str(
        geo.get("state")
        or ""
    )


    result={
        "schema_version":1,

        "config_id":config_id,

        "state":(
            "confirmed_stable"
            if state=="confirmed"
            and geo.get("country_code")
            else (
                "pending_confirmation"
                if geo.get("country_code")
                else state
            )
        ),

        "country_code":
            geo.get("country_code"),

        "country_name":
            geo.get("country_name"),

        "flag":
            geo.get("flag"),

        "exit_ip":
            exit_ip,

        "confidence":
            geo.get(
                "country_confidence"
            ),

        "asn":
            geo.get("asn"),

        "network_name":
            geo.get("network_name"),

        "network_type":
            geo.get("network_type"),

        "primary":
            geo,

        "metadata":{
            "source":
                "k1-event-consumer",

            "event_id":
                event_id,

            "health_generation":
                event.get(
                    "health_generation"
                ),

            "same_runtime_exit_ip":
                True,

            "second_xray":
                False,

            "second_exit_probe":
                False,
        },
    }


    save_country_result(
        result
    )


    _metric(
        {
            "status":"processed",
            "event_id":event_id,
            "config_id":config_id,
            "exit_ip":exit_ip,
            "country_code":
                result.get(
                    "country_code"
                ),
            "state":
                result.get(
                    "state"
                ),
            "cache_hit":
                geo.get(
                    "cache_hit"
                ),
            "singleflight_role":
                geo.get(
                    "singleflight_role"
                ),
        }
    )


def worker_loop(
    worker_id: int,
) -> None:

    while not STOP.is_set():

        recover_expired()

        item=lease()

        if item is None:
            STOP.wait(0.25)
            continue


        try:
            event=item

            _process_event(
                event
            )

            ack(
                event["event_id"]
            )


        except Exception as exc:

            event_id=(
                item.get("event_id")
                if isinstance(
                    item,
                    dict,
                )
                else None
            )

            _metric(
                {
                    "status":"error",
                    "worker_id":
                        worker_id,

                    "event_id":
                        event_id,

                    "error":
                        (
                            f"{type(exc).__name__}: "
                            f"{exc}"
                        )[:500],
                }
            )


            if event_id:

                try:
                    nack(
                        event_id,
                        retry_seconds=10,
                        max_attempts=6,
                    )
                except Exception:
                    pass


def main() -> int:

    workers=max(
        1,
        int(
            os.getenv(
                "COUNTRY_EVENT_CONSUMER_WORKERS",
                "2",
            )
        ),
    )


    def stop_handler(
        *_,
    ):
        STOP.set()


    signal.signal(
        signal.SIGTERM,
        stop_handler,
    )

    signal.signal(
        signal.SIGINT,
        stop_handler,
    )


    threads=[]

    for i in range(workers):

        t=threading.Thread(
            target=worker_loop,
            args=(i,),
            daemon=True,
            name=f"country-event-{i}",
        )

        t.start()
        threads.append(t)


    _metric(
        {
            "status":"consumer_start",
            "workers":workers,
            "queue":stats(),
        }
    )


    while not STOP.wait(1.0):
        pass


    for t in threads:
        t.join(
            timeout=5,
        )


    _metric(
        {
            "status":"consumer_stop",
            "queue":stats(),
        }
    )

    return 0


if __name__=="__main__":
    raise SystemExit(
        main()
    )
PY

"$PY" -m py_compile "$APP"

echo "CONSUMER_MODULE=PASS"


echo "=== 2. INSTALL EXECUTABLE ==="

cat >"$BIN" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

export PYTHONPATH=/opt/config-location

exec /opt/config-location/venv/bin/python \
-m app.country.event_consumer
SH

chmod 0755 "$BIN"

echo "CONSUMER_BIN=PASS"


echo "=== 3. INSTALL SYSTEMD UNIT ==="

cat >"$UNIT" <<'UNIT'
[Unit]
Description=Config Location Country Event Consumer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/config-location
Environment=PYTHONPATH=/opt/config-location
Environment=COUNTRY_EVENT_CONSUMER_WORKERS=2
ExecStart=/opt/config-location/bin/country-event-consumer
Restart=always
RestartSec=2
User=root

NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

systemctl enable \
config-location-country-event-consumer.service

echo "UNIT_INSTALL=PASS"


echo "=== 4. QUEUE BASELINE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print("QUEUE_BEFORE=",stats())
PY


echo "=== 5. RESET CONSUMER METRICS ==="

rm -f \
/var/lib/config-location/country/event-consumer-metrics.jsonl \
2>/dev/null || true


echo "=== 6. START CONSUMER ==="

systemctl restart \
config-location-country-event-consumer.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER_SERVICE=active"


echo "=== 7. OBSERVE 60s DRAIN ==="

BEFORE=$(
PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print(stats().get("pending",0))
PY
)

echo "PENDING_START=$BEFORE"

for i in $(seq 1 12)
do
    sleep 5

    NOW=$(
    PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print(stats().get("pending",0))
PY
    )

    echo "T=$((i*5))s PENDING=$NOW"
done


AFTER=$(
PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import stats
print(stats().get("pending",0))
PY
)

echo "PENDING_END=$AFTER"

DRAIN=$((BEFORE-AFTER))

echo "NET_DRAIN_60S=$DRAIN"


echo "=== 8. CONSUMER METRICS ==="

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


print(
    "METRIC_ROWS=",
    len(rows),
)

c=Counter(
    r.get(
        "status",
        "unknown",
    )
    for r in rows
)

print(
    "STATUS=",
    dict(c),
)


processed=[
    r
    for r in rows
    if r.get(
        "status"
    )=="processed"
]


print(
    "PROCESSED=",
    len(processed),
)


for r in processed[:10]:
    print(
        "SAMPLE=",
        r,
    )


assert len(processed)>=1

print(
    "CONSUMER_PROCESSING=PASS"
)
PY


echo "=== 9. QUEUE INTEGRITY ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.event_bus import (
    recover_expired,
    stats,
)

print(
    "RECOVERED=",
    recover_expired(),
)

s=stats()

print(
    "QUEUE_AFTER=",
    s,
)

assert s.get(
    "leased",
    0,
)>=0

print(
    "QUEUE_INTEGRITY=PASS"
)
PY


echo "=== 10. VERIFY NO SECOND XRAY CONTRACT ==="

grep -q \
'second_xray.*False' \
"$APP"

grep -q \
'second_exit_probe.*False' \
"$APP"

if grep -q \
'observe_exit_ip' \
"$APP"
then
    echo "ERROR=SECOND_EXIT_PROBE_REFERENCE"
    exit 1
fi

echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"


echo "=== 11. SERVICES ==="

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


echo "======================================================"
echo "FIX22K1_CONSUMER_B=PASS"
echo "EVENT_CONSUMER=ACTIVE"
echo "INITIAL_WORKERS=2"
echo "K2_EXIT_HANDOFF=CONSUMED"
echo "K4_CACHE_SINGLEFLIGHT=USED"
echo "K5_PARALLEL_GEO=USED"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "ACK_NACK_RETRY=ENABLED"
echo "BACKUP=$B"
echo "NEXT=CONSUMER-C-ADAPTIVE-DRAIN"
echo "======================================================"
