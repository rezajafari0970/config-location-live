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
                seconds=60,
            )

            if leased is None:
                STOP.wait(0.25)
                continue


            lease_path,event=leased


            _metric(
                {
                    "status":"leased",
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

                    "lease_path":
                        str(
                            lease_path
                        ),
                }
            )


            _process_event(
                event
            )


            done_path=ack(
                lease_path,
                result={
                    "consumer":
                        "k1-event-consumer",

                    "processed":
                        True,
                },
            )


            _metric(
                {
                    "status":"acked",
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

                    "done_path":
                        str(
                            done_path
                        ),
                }
            )


        except Exception as exc:

            error=(
                f"{type(exc).__name__}: "
                f"{exc}"
            )[:1000]


            _metric(
                {
                    "status":"error",
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

                    "lease_path":
                        (
                            str(
                                lease_path
                            )
                            if lease_path
                            is not None
                            else None
                        ),

                    "error":
                        error,
                }
            )


            # Only NACK if a real lease exists.
            if lease_path is not None:

                try:

                    nack(
                        lease_path,
                        error,
                        retry_seconds=10,
                        max_attempts=6,
                    )

                except Exception as nack_exc:

                    _metric(
                        {
                            "status":
                                "nack_error",

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

                            "error":
                                (
                                    f"{type(nack_exc).__name__}: "
                                    f"{nack_exc}"
                                )[:1000],
                        }
                    )


            # Never let a worker thread die.
            STOP.wait(0.10)

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
