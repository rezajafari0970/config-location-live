#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"
M="$R/app/country"

D=/var/lib/config-location/country/worker
STATE="$D/state.json"
REPORT="$D/last-run.json"

mkdir -p "$D"


echo "=== 1. CREATE COUNTRY WORKER ==="

cat >"$M/worker.py" <<'PY'
from __future__ import annotations

import fcntl
import json
import os
import tempfile
import time

from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .pipeline import process_country


CONFIG_ROOT=Path(
    "/var/lib/config-location/configs"
)

HEALTH_ROOT=Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

COUNTRY_ROOT=Path(
    "/var/lib/config-location/"
    "country/pipeline/latest"
)

WORKER_ROOT=Path(
    "/var/lib/config-location/"
    "country/worker"
)

STATE_PATH=WORKER_ROOT/"state.json"
REPORT_PATH=WORKER_ROOT/"last-run.json"

LOCK_PATH=Path(
    "/run/config-location-country-worker.lock"
)


RETRY_SECONDS={
    "missing":0,

    "pending_confirmation":
        5 * 60,

    "unknown":
        10 * 60,

    "ambiguous":
        10 * 60,

    "unstable_exit":
        10 * 60,

    "error":
        15 * 60,

    "confirmed_rotating_ip":
        6 * 60 * 60,

    "confirmed_stable":
        12 * 60 * 60,

    "rotating":
        30 * 60,
}


def now_epoch() -> int:
    return int(
        time.time()
    )


def utc_now() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def atomic_json(
    path: Path,
    value: dict[str, Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd,tmp=tempfile.mkstemp(
        dir=str(path.parent),
        prefix="."+path.name+".",
        suffix=".tmp",
    )

    try:

        with os.fdopen(
            fd,
            "w",
            encoding="utf-8",
        ) as f:

            json.dump(
                value,
                f,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            f.write("\n")
            f.flush()
            os.fsync(
                f.fileno()
            )

        os.replace(
            tmp,
            path,
        )

    except Exception:

        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass

        raise


class CountryWorkerLock:

    def __init__(
        self,
        path: Path=LOCK_PATH,
    ):
        self.path=path
        self.fd=None


    def __enter__(self):

        self.path.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        self.fd=open(
            self.path,
            "a+",
        )

        try:
            fcntl.flock(
                self.fd.fileno(),
                (
                    fcntl.LOCK_EX
                    |
                    fcntl.LOCK_NB
                ),
            )

        except BlockingIOError:

            self.fd.close()
            self.fd=None

            raise RuntimeError(
                "country_worker_already_running"
            )

        return self


    def __exit__(
        self,
        exc_type,
        exc,
        tb,
    ):

        if self.fd is not None:

            try:
                fcntl.flock(
                    self.fd.fileno(),
                    fcntl.LOCK_UN,
                )
            finally:
                self.fd.close()


def load_json(
    path: Path,
) -> dict[str, Any] | None:

    try:
        o=json.loads(
            path.read_text()
        )
    except Exception:
        return None

    return (
        o
        if isinstance(o,dict)
        else None
    )


def load_worker_state() -> dict[str, Any]:

    o=load_json(
        STATE_PATH
    )

    if not o:
        return {
            "schema_version":1,
            "records":{},
        }

    records=o.get(
        "records"
    )

    if not isinstance(
        records,
        dict,
    ):
        records={}

    return {
        "schema_version":1,
        "records":records,
    }


def country_state(
    config_id: str,
) -> str:

    p=(
        COUNTRY_ROOT
        / f"{config_id}.json"
    )

    o=load_json(
        p
    )

    if not o:
        return "missing"

    return str(
        o.get(
            "state",
            "unknown",
        )
    ).strip().lower()


def healthy_candidates() -> list[
    tuple[int,str,dict,dict]
]:

    now=now_epoch()

    state=load_worker_state()

    worker_records=state[
        "records"
    ]

    result=[]


    for hp in HEALTH_ROOT.glob(
        "*.json"
    ):

        health=load_json(
            hp
        )

        if not health:
            continue

        if str(
            health.get(
                "state",
                "",
            )
        ).lower() != "healthy":
            continue


        config_id=hp.stem

        cp=(
            CONFIG_ROOT
            / f"{config_id}.json"
        )

        record=load_json(
            cp
        )

        if not record:
            continue


        cstate=country_state(
            config_id
        )


        previous=worker_records.get(
            config_id,
            {}
        )

        last_run=int(
            previous.get(
                "last_run_epoch",
                0,
            )
            or 0
        )


        retry=RETRY_SECONDS.get(
            cstate,
            30 * 60,
        )


        due=(
            last_run
            + retry
        )


        if now < due:
            continue


        # Lower number = higher priority.
        priority={
            "missing":0,
            "unknown":1,
            "ambiguous":1,
            "unstable_exit":1,
            "error":2,
            "pending_confirmation":3,
            "rotating":4,
            "confirmed_rotating_ip":5,
            "confirmed_stable":6,
        }.get(
            cstate,
            3,
        )


        result.append(
            (
                priority,
                config_id,
                record,
                health,
            )
        )


    result.sort(
        key=lambda x:(
            x[0],
            x[1],
        )
    )

    return result


def run_country_worker_once(
    *,
    max_jobs: int=10,
) -> dict[str, Any]:

    WORKER_ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )


    with CountryWorkerLock():

        started=utc_now()

        worker_state=(
            load_worker_state()
        )

        records=worker_state[
            "records"
        ]


        candidates=(
            healthy_candidates()
        )


        selected=candidates[
            :max_jobs
        ]


        stats=Counter()

        processed=[]


        for (
            priority,
            config_id,
            record,
            health,
        ) in selected:

            before=country_state(
                config_id
            )

            try:

                result=process_country(
                    config_id=config_id,
                    record=record,
                    health=health,
                )

            except Exception as e:

                result={
                    "config_id":
                        config_id,

                    "state":
                        "error",

                    "reason":
                        "worker_pipeline_exception",

                    "error":
                        str(e)[:1000],
                }


            final_state=str(
                result.get(
                    "state",
                    "error",
                )
            )


            stats[
                final_state
            ] += 1


            records[
                config_id
            ]={
                "last_run_at":
                    utc_now(),

                "last_run_epoch":
                    now_epoch(),

                "previous_country_state":
                    before,

                "result_state":
                    final_state,

                "country_code":
                    result.get(
                        "country_code"
                    ),

                "exit_ip":
                    result.get(
                        "exit_ip"
                    ),
            }


            processed.append(
                {
                    "config_id":
                        config_id,

                    "priority":
                        priority,

                    "previous_state":
                        before,

                    "result_state":
                        final_state,

                    "country_code":
                        result.get(
                            "country_code"
                        ),

                    "exit_ip":
                        result.get(
                            "exit_ip"
                        ),

                    "reason":
                        result.get(
                            "reason"
                        ),

                    "error":
                        result.get(
                            "error"
                        ),
                }
            )


        # GC worker state against current config store.
        current_ids={
            p.stem
            for p in CONFIG_ROOT.glob(
                "*.json"
            )
        }

        stale=[
            config_id
            for config_id in records
            if config_id
            not in current_ids
        ]

        for config_id in stale:
            records.pop(
                config_id,
                None,
            )


        worker_state[
            "updated_at"
        ]=utc_now()

        worker_state[
            "records"
        ]=records

        worker_state[
            "gc_removed"
        ]=len(stale)


        atomic_json(
            STATE_PATH,
            worker_state,
        )


        report={
            "schema_version":1,

            "mode":
                "shadow",

            "started_at":
                started,

            "finished_at":
                utc_now(),

            "eligible_due":
                len(candidates),

            "selected":
                len(selected),

            "processed":
                len(processed),

            "states":
                dict(stats),

            "gc_removed":
                len(stale),

            "jobs":
                processed,
        }


        atomic_json(
            REPORT_PATH,
            report,
        )


        return report
PY


echo "=== 2. COMPILE ==="

"$PY" -m py_compile \
"$M/worker.py"

echo "COMPILE=PASS"


echo "=== 3. LOCK SELFTEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.worker import (
    CountryWorkerLock,
)

with CountryWorkerLock():

    try:

        with CountryWorkerLock():
            raise AssertionError(
                "second lock acquired"
            )

    except RuntimeError as e:

        assert (
            str(e)
            ==
            "country_worker_already_running"
        )

print(
    "COUNTRY_WORKER_LOCK=PASS"
)
PY


echo "=== 4. SCHEDULER AUDIT ==="

PYTHONPATH="$R" "$PY" <<'PY'
from collections import Counter

from app.country.worker import (
    healthy_candidates,
    country_state,
)

rows=healthy_candidates()

states=Counter(
    country_state(
        cid
    )
    for _,cid,_,_
    in rows
)

print(
    "DUE_CANDIDATES=",
    len(rows),
)

print(
    "DUE_STATES=",
    dict(states),
)

print(
    "FIRST_20="
)

for priority,cid,_,_ in rows[:20]:

    print(
        priority,
        cid[:16],
        country_state(cid),
    )

assert len(rows) > 0

# New/missing Country records must naturally
# be among the highest priority population.
assert any(
    country_state(cid)=="missing"
    for _,cid,_,_
    in rows
)

print(
    "COUNTRY_SCHEDULER=PASS"
)
PY


echo "=== 5. SHADOW REAL BATCH ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.worker import (
    run_country_worker_once,
)

r=run_country_worker_once(
    max_jobs=10
)

print(
    "MODE=",
    r["mode"],
)

print(
    "ELIGIBLE_DUE=",
    r["eligible_due"],
)

print(
    "SELECTED=",
    r["selected"],
)

print(
    "PROCESSED=",
    r["processed"],
)

print(
    "STATES=",
    r["states"],
)

for job in r["jobs"]:

    print(
        "JOB",
        job["config_id"][:12],
        "priority=",
        job["priority"],
        "before=",
        job["previous_state"],
        "after=",
        job["result_state"],
        "country=",
        job["country_code"],
        "exit=",
        job["exit_ip"],
        "error=",
        job["error"],
    )


assert r["mode"]=="shadow"
assert r["selected"]==10
assert r["processed"]==10

print(
    "SHADOW_BATCH=PASS"
)
PY


echo "=== 6. WORKER STATE VERIFY ==="

"$PY" <<'PY'
from pathlib import Path
import json

S=Path(
    "/var/lib/config-location/"
    "country/worker/state.json"
)

R=Path(
    "/var/lib/config-location/"
    "country/worker/last-run.json"
)

assert S.exists()
assert R.exists()

state=json.loads(
    S.read_text()
)

report=json.loads(
    R.read_text()
)

records=state.get(
    "records",
    {}
)

print(
    "WORKER_TRACKED=",
    len(records),
)

print(
    "LAST_RUN_PROCESSED=",
    report.get(
        "processed"
    ),
)

print(
    "GC_REMOVED=",
    state.get(
        "gc_removed"
    ),
)

assert isinstance(
    records,
    dict,
)

assert report[
    "mode"
]=="shadow"

assert report[
    "processed"
]==10

print(
    "WORKER_STATE=PASS"
)
PY


echo "=== 7. HEALTH ISOLATION ==="

for svc in \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service \
config-location-panel.service
do
    X=$(
        systemctl is-active \
        "$svc" \
        2>/dev/null || true
    )

    echo "$svc=$X"

    test "$X" = active
done

echo "HEALTH_FETCHER_ISOLATION=PASS"


echo "=== 8. SANDBOX CLEANUP ==="

COUNT=$(
    find \
    /var/lib/config-location/health-sandboxes \
    -maxdepth 1 \
    -type d \
    -name "country-*" \
    2>/dev/null \
    | wc -l
)

echo "COUNTRY_SANDBOX_RESIDUAL=$COUNT"

test "$COUNT" -eq 0

echo "RUNTIME_CLEANUP=PASS"


echo "=== 9. PERMANENT SERVICE CHECK ==="

if systemctl list-unit-files \
| grep -q '^config-location-country-worker.service'; then

    echo "COUNTRY_SERVICE_EXISTS=YES"

    X=$(
        systemctl is-enabled \
        config-location-country-worker.service \
        2>/dev/null || true
    )

    echo "COUNTRY_SERVICE_ENABLED=$X"

    test "$X" != enabled

else

    echo "COUNTRY_SERVICE_EXISTS=NO"

fi

echo "PERMANENT_DAEMON=NOT_ENABLED"


echo "========================================"
echo "FIX22H1B=PASS"
echo "COUNTRY_WORKER_FOUNDATION=READY"
echo "COUNTRY_WORKER_LOCK=INDEPENDENT"
echo "HEALTHY_ONLY_SCHEDULING=YES"
echo "MISSING_COUNTRY_PRIORITY=HIGHEST"
echo "CONFIRMED_RETEST_INTERVAL=LONG"
echo "UNKNOWN_RETRY_INTERVAL=SHORT"
echo "STATE_GC=READY"
echo "SHADOW_BATCH=10"
echo "HEALTH_FETCHER_ISOLATION=PASS"
echo "RUNTIME_CLEANUP=PASS"
echo "PERMANENT_COUNTRY_DAEMON=NOT_ENABLED"
echo "========================================"
