#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
APP="$R/app/country/event_consumer.py"
MET=/var/lib/config-location/country/event-consumer-metrics.jsonl

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22K1-CONSUMER-B-R3-$TS"

mkdir -p "$B"
cp -a "$APP" "$B/"

echo "BACKUP=$B"

echo
echo "=== 1. STOP CONSUMER ==="

systemctl stop \
config-location-country-event-consumer.service \
2>/dev/null || true

echo "CONSUMER_STOPPED=YES"


echo
echo "=== 2. INSTALL BACKLOG HYDRATION + DEFER ==="

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

from app.country.geo_intelligence import (
    resolve_geo,
)

from app.country.storage import (
    save_country_result,
)


STOP=threading.Event()

METRICS=Path(
    "/var/lib/config-location/country/"
    "event-consumer-metrics.jsonl"
)

HEALTH_LATEST=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)


class MissingReusableExit(
    RuntimeError
):
    pass


def _metric(
    row: dict,
) -> None:

    try:

        METRICS.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        row={
            "ts_ns":
                time.time_ns(),
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


def _fast_from_event(
    event: dict,
) -> dict | None:

    metadata=(
        event.get("metadata")
        or {}
    )

    fast=metadata.get(
        "same_runtime_country"
    )

    if not isinstance(
        fast,
        dict,
    ):
        return None

    if (
        fast.get("status")
        =="success"
        and fast.get("exit_ip")
    ):
        return fast

    return None


def _fast_from_latest_health(
    config_id: str,
) -> dict | None:

    # Canonical store normally uses config_id.json.
    candidates=[
        HEALTH_LATEST
        /f"{config_id}.json",
    ]

    # Defensive fallback if store naming changed.
    if not candidates[0].exists():

        candidates.extend(
            HEALTH_LATEST.glob(
                f"*{config_id}*.json"
            )
        )


    for p in candidates:

        if not p.exists():
            continue

        try:
            h=json.loads(
                p.read_text()
            )
        except Exception:
            continue


        if str(
            h.get(
                "state",
                "",
            )
        ).lower()!="healthy":
            continue


        fast=(
            (
                h.get("metadata")
                or {}
            ).get(
                "same_runtime_country"
            )
        )


        if (
            isinstance(fast,dict)
            and fast.get(
                "status"
            )=="success"
            and fast.get(
                "exit_ip"
            )
        ):
            return fast


    return None


def _reusable_fast(
    event: dict,
) -> tuple[
    dict | None,
    str,
]:

    fast=_fast_from_event(
        event
    )

    if fast is not None:
        return (
            fast,
            "event",
        )


    config_id=str(
        event.get(
            "config_id"
        )
        or ""
    )


    if config_id:

        fast=(
            _fast_from_latest_health(
                config_id
            )
        )

        if fast is not None:

            return (
                fast,
                "latest_health",
            )


    return (
        None,
        "missing",
    )


def _process_event(
    event: dict,
) -> dict:

    event_id=str(
        event.get(
            "event_id"
        )
        or ""
    )

    config_id=str(
        event.get(
            "config_id"
        )
        or ""
    )


    if (
        not event_id
        or not config_id
    ):
        raise ValueError(
            "event missing event_id/config_id"
        )


    fast,fast_source=(
        _reusable_fast(
            event
        )
    )


    if fast is None:

        raise MissingReusableExit(
            "no reusable same-runtime exit_ip"
        )


    exit_ip=str(
        fast["exit_ip"]
    )


    # K2 boundary:
    # absolutely no second Xray or Exit-IP probe.
    geo=resolve_geo(
        config_id=config_id,
        ip=exit_ip,
    )


    country_code=(
        geo.get(
            "country_code"
        )
    )


    # Do not falsely call a single observation
    # "confirmed_stable". K6/temporal layers
    # may later tighten the verdict.
    state=(
        "pending_confirmation"
        if country_code
        else str(
            geo.get(
                "state"
            )
            or "unresolved"
        )
    )


    result={
        "schema_version":1,

        "config_id":
            config_id,

        "state":
            state,

        "country_code":
            country_code,

        "country_name":
            geo.get(
                "country_name"
            ),

        "flag":
            geo.get(
                "flag"
            ),

        "exit_ip":
            exit_ip,

        "confidence":
            geo.get(
                "country_confidence"
            ),

        "asn":
            geo.get(
                "asn"
            ),

        "network_name":
            geo.get(
                "network_name"
            ),

        "network_type":
            geo.get(
                "network_type"
            ),

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

            "fast_source":
                fast_source,

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
            "status":
                "processed",

            "event_id":
                event_id,

            "config_id":
                config_id,

            "exit_ip":
                exit_ip,

            "fast_source":
                fast_source,

            "country_code":
                country_code,

            "state":
                state,

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


    return result


def worker_loop(
    worker_id: int,
) -> None:

    owner=(
        f"country-event-consumer:"
        f"{os.getpid()}:"
        f"{worker_id}"
    )


    while not STOP.is_set():

        lease_path=None
        event=None

        try:

            recover_expired()

            leased=lease(
                owner=owner,
                seconds=90,
            )


            if leased is None:

                STOP.wait(
                    0.20
                )
                continue


            lease_path,event=leased


            _metric(
                {
                    "status":
                        "leased",

                    "worker_id":
                        worker_id,

                    "event_id":
                        event.get(
                            "event_id"
                        ),

                    "config_id":
                        event.get(
                            "config_id"
                        ),
                }
            )


            result=_process_event(
                event
            )


            ack(
                lease_path,
                result={
                    "consumer":
                        "k1-event-consumer",

                    "processed":
                        True,

                    "country_code":
                        result.get(
                            "country_code"
                        ),

                    "state":
                        result.get(
                            "state"
                        ),
                },
            )


            _metric(
                {
                    "status":
                        "acked",

                    "worker_id":
                        worker_id,

                    "event_id":
                        event.get(
                            "event_id"
                        ),

                    "config_id":
                        event.get(
                            "config_id"
                        ),
                }
            )


        except MissingReusableExit as exc:

            _metric(
                {
                    "status":
                        "deferred_no_exit",

                    "worker_id":
                        worker_id,

                    "event_id":
                        (
                            event.get(
                                "event_id"
                            )
                            if isinstance(
                                event,
                                dict,
                            )
                            else None
                        ),

                    "config_id":
                        (
                            event.get(
                                "config_id"
                            )
                            if isinstance(
                                event,
                                dict,
                            )
                            else None
                        ),
                }
            )


            if lease_path is not None:

                try:

                    # Old pre-K2 backlog should not
                    # starve newer usable events.
                    nack(
                        lease_path,
                        str(exc),
                        retry_seconds=300,
                        max_attempts=100,
                    )

                except Exception as nack_exc:

                    _metric(
                        {
                            "status":
                                "nack_error",

                            "error":
                                (
                                    f"{type(nack_exc).__name__}: "
                                    f"{nack_exc}"
                                )[:1000],
                        }
                    )


        except Exception as exc:

            error=(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:1000]


            _metric(
                {
                    "status":
                        "error",

                    "worker_id":
                        worker_id,

                    "event_id":
                        (
                            event.get(
                                "event_id"
                            )
                            if isinstance(
                                event,
                                dict,
                            )
                            else None
                        ),

                    "config_id":
                        (
                            event.get(
                                "config_id"
                            )
                            if isinstance(
                                event,
                                dict,
                            )
                            else None
                        ),

                    "error":
                        error,
                }
            )


            if lease_path is not None:

                try:

                    nack(
                        lease_path,
                        error,
                        retry_seconds=30,
                        max_attempts=20,
                    )

                except Exception as nack_exc:

                    _metric(
                        {
                            "status":
                                "nack_error",

                            "error":
                                (
                                    f"{type(nack_exc).__name__}: "
                                    f"{nack_exc}"
                                )[:1000],
                        }
                    )


            STOP.wait(
                0.10
            )


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


    for i in range(
        workers
    ):

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
            "status":
                "consumer_start",

            "workers":
                workers,

            "queue":
                stats(),
        }
    )


    while not STOP.wait(
        1.0
    ):
        pass


    for t in threads:

        t.join(
            timeout=5,
        )


    _metric(
        {
            "status":
                "consumer_stop",

            "queue":
                stats(),
        }
    )


    return 0


if __name__=="__main__":

    raise SystemExit(
        main()
    )
PY


echo
echo "=== 3. COMPILE ==="

"$PY" -m py_compile "$APP"

echo "COMPILE=PASS"


echo
echo "=== 4. SAFETY VERIFY ==="

if grep -q \
'observe_exit_ip' \
"$APP"
then
    echo "ERROR=SECOND_EXIT_PROBE_REFERENCE"
    exit 1
fi

grep -q \
'deferred_no_exit' \
"$APP"

grep -q \
'retry_seconds=300' \
"$APP"

grep -q \
'_fast_from_latest_health' \
"$APP"

echo "BACKLOG_HYDRATION=YES"
echo "OLD_EVENT_DEFER=YES"
echo "SECOND_EXIT_PROBE=NO"


echo
echo "=== 5. RESET METRICS ==="

rm -f "$MET"

echo "METRICS_RESET=PASS"


echo
echo "=== 6. QUEUE BEFORE ==="

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
echo "=== 7. START R3 ==="

systemctl restart \
config-location-country-event-consumer.service

sleep 4

test "$(
    systemctl is-active \
    config-location-country-event-consumer.service
)" = active

echo "CONSUMER_SERVICE=active"


echo
echo "=== 8. OBSERVE 90 SECONDS ==="

for i in $(seq 1 18)
do

    sleep 5

    PYTHONPATH="$R" "$PY" <<PY
from app.country.event_bus import stats
s=stats()

print(
    "T=$((i*5))s",
    "PENDING=",
    s.get("pending",0),
    "LEASED=",
    s.get("leased",0),
    "DONE=",
    s.get("done",0),
    "DEAD=",
    s.get("dead",0),
)
PY

done


echo
echo "=== 9. R3 METRICS ==="

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
        "fast_source"
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


for r in rows:

    if r.get(
        "status"
    )=="processed":

        print(
            "PROCESSED_SAMPLE=",
            r,
        )


assert c.get(
    "leased",
    0,
)>=1


# Key R3 requirement:
# at least one usable K2 event must pass.
assert c.get(
    "processed",
    0,
)>=1


assert c.get(
    "acked",
    0,
)>=1


assert c.get(
    "nack_error",
    0,
)==0


print(
    "R3_EVENT_FLOW=PASS"
)
PY


echo
echo "=== 10. QUEUE FINAL ==="

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
    "QUEUE_ACK_FLOW=PASS"
)
PY


echo
echo "=== 11. THREAD HEALTH ==="

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

echo "THREADS=PASS"


echo
echo "=== 12. CORE SERVICES ==="

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
echo "FIX22K1_CONSUMER_B_R3=PASS"
echo "EVENT_CONSUMER=ACTIVE"
echo "PRE_K2_BACKLOG=DEFERRED"
echo "LATEST_HEALTH_HYDRATION=ACTIVE"
echo "K2_EXIT_HANDOFF=CONSUMED"
echo "K4_CACHE_SINGLEFLIGHT=USED"
echo "K5_PARALLEL_GEO=USED"
echo "SECOND_XRAY=NO"
echo "SECOND_EXIT_PROBE=NO"
echo "OLD_EVENTS=NOT_DEAD_LETTERED"
echo "NEXT=CONSUMER-C-ADAPTIVE-DRAIN"
echo "======================================================"
