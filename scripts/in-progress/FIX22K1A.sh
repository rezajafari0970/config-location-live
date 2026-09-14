#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
M="$R/app/country"
Q=/var/lib/config-location/country/event-bus

mkdir -p "$Q"

cat >"$M/event_bus.py" <<'PY'
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import tempfile
import time
import uuid

from pathlib import Path
from typing import Any


ROOT=Path(
    "/var/lib/config-location/"
    "country/event-bus"
)

PENDING=ROOT/"pending"
LEASED=ROOT/"leased"
DONE=ROOT/"done"
DEAD=ROOT/"dead-letter"
LOCK=ROOT/"queue.lock"

COUNTRY_RESULTS=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

FINAL={
    "confirmed",
    "confirmed_stable",
    "confirmed_rotating_ip",
}


def now() -> int:
    return int(time.time())


def dirs() -> None:
    for p in (
        ROOT,
        PENDING,
        LEASED,
        DONE,
        DEAD,
    ):
        p.mkdir(
            parents=True,
            exist_ok=True,
        )


def read(path: Path):
    try:
        o=json.loads(
            path.read_text()
        )
    except Exception:
        return None

    return o if isinstance(o,dict) else None


def write(
    path: Path,
    o: dict[str,Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd,tmp=tempfile.mkstemp(
        dir=str(path.parent),
        prefix=".queue-",
        suffix=".tmp",
    )

    try:
        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as f:
            json.dump(
                o,
                f,
                ensure_ascii=False,
                sort_keys=True,
            )
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())

        os.replace(tmp,path)

    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


class Lock:

    def __enter__(self):
        dirs()
        self.f=open(LOCK,"a+")
        fcntl.flock(
            self.f.fileno(),
            fcntl.LOCK_EX,
        )
        return self

    def __exit__(
        self,
        exc_type,
        exc,
        tb,
    ):
        fcntl.flock(
            self.f.fileno(),
            fcntl.LOCK_UN,
        )
        self.f.close()


def key(
    config_id: str,
    generation: str,
) -> str:

    return hashlib.sha256(
        (
            config_id
            +"\0"
            +generation
        ).encode()
    ).hexdigest()


def is_final(
    config_id: str,
) -> bool:

    o=read(
        COUNTRY_RESULTS
        /f"{config_id}.json"
    )

    return bool(
        o
        and str(
            o.get("state","")
        ).lower()
        in FINAL
    )


def locate(k: str):

    for state,root in (
        ("pending",PENDING),
        ("leased",LEASED),
        ("done",DONE),
        ("dead",DEAD),
    ):
        x=list(
            root.glob(
                f"*{k}*.json"
            )
        )

        if x:
            return state,x[0]

    return None


def enqueue(
    *,
    config_id: str,
    generation: str,
    completed_at: str,
    priority: int=0,
    metadata=None,
):

    dirs()

    k=key(
        config_id,
        generation,
    )

    with Lock():

        if is_final(config_id):
            return {
                "status":
                    "suppressed_final",
                "key":k,
            }

        old=locate(k)

        if old:
            return {
                "status":"duplicate",
                "state":old[0],
                "key":k,
            }

        o={
            "schema_version":1,
            "event_id":
                str(uuid.uuid4()),
            "event_key":k,
            "config_id":config_id,
            "health_generation":
                generation,
            "health_completed_at":
                completed_at,
            "priority":
                int(priority),
            "attempt":0,
            "created_epoch":now(),
            "not_before_epoch":0,
            "metadata":
                metadata or {},
        }

        p=PENDING/(
            f"{int(priority):03d}-"
            f"{k}.json"
        )

        write(p,o)

        return {
            "status":"enqueued",
            "key":k,
        }


def recover_expired() -> int:

    dirs()
    n=0
    t=now()

    with Lock():

        for p in list(
            LEASED.glob("*.json")
        ):
            o=read(p)

            if not o:
                continue

            if int(
                o.get(
                    "lease_until_epoch",
                    0,
                )
            ) > t:
                continue

            o.pop(
                "lease_owner",
                None,
            )
            o.pop(
                "lease_until_epoch",
                None,
            )

            target=PENDING/(
                f"{int(o.get('priority',0)):03d}-"
                f"{o['event_key']}.json"
            )

            write(target,o)
            p.unlink(
                missing_ok=True
            )
            n+=1

    return n


def lease(
    owner: str,
    seconds: int=60,
):

    dirs()
    t=now()

    with Lock():

        rows=[]

        for p in PENDING.glob(
            "*.json"
        ):
            o=read(p)

            if not o:
                continue

            if int(
                o.get(
                    "not_before_epoch",
                    0,
                )
            ) > t:
                continue

            rows.append(
                (
                    int(
                        o.get(
                            "priority",
                            0,
                        )
                    ),
                    int(
                        o.get(
                            "created_epoch",
                            0,
                        )
                    ),
                    p,
                    o,
                )
            )

        if not rows:
            return None

        rows.sort(
            key=lambda x:(
                x[0],
                x[1],
                x[2].name,
            )
        )

        _,_,p,o=rows[0]

        if is_final(
            o["config_id"]
        ):
            target=DONE/(
                o["event_key"]
                +".json"
            )
            o["done_reason"]=(
                "already_final"
            )
            write(target,o)
            p.unlink(
                missing_ok=True
            )
            return None

        o["lease_owner"]=owner
        o["lease_until_epoch"]=(
            t+max(5,int(seconds))
        )

        target=LEASED/(
            o["event_key"]
            +".json"
        )

        write(target,o)
        p.unlink(
            missing_ok=True
        )

        return target,o


def ack(
    lease_path: Path,
    result=None,
):

    with Lock():
        o=read(lease_path)

        if not o:
            raise RuntimeError(
                "lease_missing"
            )

        o.pop(
            "lease_owner",
            None,
        )
        o.pop(
            "lease_until_epoch",
            None,
        )

        o["done_reason"]="processed"

        if result is not None:
            o["result"]=result

        target=DONE/(
            o["event_key"]
            +".json"
        )

        write(target,o)

        lease_path.unlink(
            missing_ok=True
        )

        return target


def nack(
    lease_path: Path,
    error: str,
    *,
    retry_seconds: int=10,
    max_attempts: int=6,
):

    with Lock():
        o=read(lease_path)

        if not o:
            raise RuntimeError(
                "lease_missing"
            )

        attempt=int(
            o.get("attempt",0)
        )+1

        o["attempt"]=attempt
        o["last_error"]=(
            str(error)[:1000]
        )

        o.pop(
            "lease_owner",
            None,
        )
        o.pop(
            "lease_until_epoch",
            None,
        )

        k=o["event_key"]

        if attempt>=max_attempts:
            target=DEAD/(
                k+".json"
            )

        else:
            delay=min(
                900,
                max(
                    1,
                    int(retry_seconds)
                )
                *(
                    2 ** min(
                        attempt-1,
                        5,
                    )
                ),
            )

            o["not_before_epoch"]=(
                now()+delay
            )

            target=PENDING/(
                f"{int(o.get('priority',0)):03d}-"
                f"{k}.json"
            )

        write(target,o)

        lease_path.unlink(
            missing_ok=True
        )

        return target


def stats():

    dirs()

    return {
        "pending":
            len(list(
                PENDING.glob(
                    "*.json"
                )
            )),
        "leased":
            len(list(
                LEASED.glob(
                    "*.json"
                )
            )),
        "done":
            len(list(
                DONE.glob(
                    "*.json"
                )
            )),
        "dead":
            len(list(
                DEAD.glob(
                    "*.json"
                )
            )),
    }
PY

echo "=== COMPILE ==="

"$PY" -m py_compile \
"$M/event_bus.py"

echo "========================================"
echo "FIX22K1A=PASS"
echo "EVENT_BUS_CORE=INSTALLED"
echo "HEALTH_HOOK=NOT_INSTALLED"
echo "COUNTRY_CONSUMER=NOT_INSTALLED"
echo "PRODUCTION_FLOW=UNCHANGED"
echo "========================================"
