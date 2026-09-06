#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location
PY="$R/venv/bin/python"

M="$R/app/country"
UNIT=/etc/systemd/system/config-location-country-worker.service

TS=$(date -u +%Y%m%d-%H%M%S)
B="$R/backups/FIX22H6-$TS"

mkdir -p "$B"

cp -a "$M/worker.py" "$B/"
cp -a "$M/daemon.py" "$B/"
cp -a "$UNIT" "$B/"

echo "BACKUP=$B"


echo "=== 1. CREATE ADAPTIVE CONTROLLER ==="

cat >"$M/adaptive.py" <<'PY'
from __future__ import annotations

import json
import os
import time

from dataclasses import dataclass
from pathlib import Path


SANDBOX_ROOT=Path(
    "/var/lib/config-location/"
    "health-sandboxes"
)

HEALTH_REPORT=Path(
    "/var/lib/config-location/"
    "health-adaptive/last-run.json"
)


@dataclass(frozen=True)
class AdaptiveDecision:

    level: str

    concurrency: int

    max_jobs: int

    interval: int

    load1: float

    cpu_count: int

    load_ratio: float

    health_runtime_count: int

    country_runtime_count: int

    reason: str


def _runtime_counts() -> tuple[int,int]:

    health=0
    country=0

    if not SANDBOX_ROOT.exists():
        return 0,0

    try:

        for p in SANDBOX_ROOT.iterdir():

            if not p.is_dir():
                continue

            if p.name.startswith(
                "country-"
            ):
                country+=1
            else:
                health+=1

    except Exception:
        pass

    return health,country


def _health_backlog_signal() -> bool:

    if not HEALTH_REPORT.exists():
        return False

    try:
        o=json.loads(
            HEALTH_REPORT.read_text()
        )
    except Exception:
        return False

    # Defensive support for multiple report schemas.
    for key in (
        "queue_size",
        "queued",
        "pending",
        "due",
        "eligible_due",
        "backlog",
    ):

        value=o.get(key)

        if isinstance(
            value,
            (int,float),
        ):

            if value >= 50:
                return True

    return False


def decide_adaptive_rate() -> AdaptiveDecision:

    cpu=max(
        1,
        os.cpu_count() or 1,
    )

    try:
        load1=os.getloadavg()[0]
    except Exception:
        load1=0.0

    ratio=load1/cpu

    (
        health_runtime_count,
        country_runtime_count,
    )=_runtime_counts()

    health_backlog=(
        _health_backlog_signal()
    )


    # --------------------------------------------------
    # Health always wins.
    # --------------------------------------------------

    if health_runtime_count >= 6:

        return AdaptiveDecision(
            level="health_priority",
            concurrency=1,
            max_jobs=1,
            interval=30,
            load1=load1,
            cpu_count=cpu,
            load_ratio=ratio,
            health_runtime_count=
                health_runtime_count,
            country_runtime_count=
                country_runtime_count,
            reason="many_health_runtimes",
        )


    if (
        health_backlog
        or ratio >= 0.90
    ):

        return AdaptiveDecision(
            level="pressure",
            concurrency=1,
            max_jobs=2,
            interval=20,
            load1=load1,
            cpu_count=cpu,
            load_ratio=ratio,
            health_runtime_count=
                health_runtime_count,
            country_runtime_count=
                country_runtime_count,
            reason=(
                "health_backlog_or_high_load"
            ),
        )


    if (
        health_runtime_count >= 3
        or ratio >= 0.70
    ):

        return AdaptiveDecision(
            level="busy",
            concurrency=2,
            max_jobs=4,
            interval=12,
            load1=load1,
            cpu_count=cpu,
            load_ratio=ratio,
            health_runtime_count=
                health_runtime_count,
            country_runtime_count=
                country_runtime_count,
            reason="moderate_pressure",
        )


    if (
        health_runtime_count >= 1
        or ratio >= 0.45
    ):

        return AdaptiveDecision(
            level="balanced",
            concurrency=3,
            max_jobs=6,
            interval=8,
            load1=load1,
            cpu_count=cpu,
            load_ratio=ratio,
            health_runtime_count=
                health_runtime_count,
            country_runtime_count=
                country_runtime_count,
            reason="shared_capacity",
        )


    # Server is relaxed: Country may accelerate.
    if ratio < 0.20:

        concurrency=min(
            6,
            max(
                3,
                cpu // 2,
            ),
        )

        return AdaptiveDecision(
            level="fast",
            concurrency=concurrency,
            max_jobs=min(
                18,
                concurrency * 3,
            ),
            interval=4,
            load1=load1,
            cpu_count=cpu,
            load_ratio=ratio,
            health_runtime_count=
                health_runtime_count,
            country_runtime_count=
                country_runtime_count,
            reason="server_idle",
        )


    concurrency=min(
        4,
        max(
            2,
            cpu // 3,
        ),
    )

    return AdaptiveDecision(
        level="normal",
        concurrency=concurrency,
        max_jobs=min(
            12,
            concurrency * 3,
        ),
        interval=6,
        load1=load1,
        cpu_count=cpu,
        load_ratio=ratio,
        health_runtime_count=
            health_runtime_count,
        country_runtime_count=
            country_runtime_count,
        reason="normal_capacity",
    )
PY


echo "=== 2. ADD SAFE PARALLEL WORKER ==="

cat >>"$M/worker.py" <<'PY'


def run_country_worker_adaptive(
    *,
    max_jobs: int,
    concurrency: int,
):
    """
    Adaptive parallel Country batch.

    Selection and global ownership remain protected by
    the Country Worker lock.

    Each config owns an independent Xray sandbox.
    """

    from concurrent.futures import (
        ThreadPoolExecutor,
        as_completed,
    )

    concurrency=max(
        1,
        min(
            int(concurrency),
            8,
        ),
    )

    max_jobs=max(
        1,
        min(
            int(max_jobs),
            24,
        ),
    )


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


        def execute(item):

            (
                priority,
                config_id,
                record,
                health,
            )=item

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
                        "adaptive_worker_exception",

                    "error":
                        str(e)[:1000],
                }

            return (
                priority,
                config_id,
                before,
                result,
            )


        completed=[]


        with ThreadPoolExecutor(
            max_workers=concurrency,
            thread_name_prefix=
                "country",
        ) as pool:

            futures=[
                pool.submit(
                    execute,
                    item,
                )
                for item
                in selected
            ]


            for future in as_completed(
                futures
            ):

                completed.append(
                    future.result()
                )


        stats=Counter()

        processed=[]


        for (
            priority,
            config_id,
            before,
            result,
        ) in completed:

            final_state=str(
                result.get(
                    "state",
                    "error",
                )
            )

            stats[
                final_state
            ]+=1


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


        current_ids={
            p.stem
            for p in CONFIG_ROOT.glob(
                "*.json"
            )
        }

        stale=[
            cid
            for cid in records
            if cid not in current_ids
        ]

        for cid in stale:
            records.pop(
                cid,
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
            "schema_version":2,

            "mode":
                "adaptive",

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

            "concurrency":
                concurrency,

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


echo "=== 3. REPLACE DAEMON WITH ADAPTIVE MODE ==="

cat >"$M/daemon.py" <<'PY'
from __future__ import annotations

import signal
import time
import traceback

from datetime import (
    datetime,
    timezone,
)

from .adaptive import (
    decide_adaptive_rate,
)

from .worker import (
    run_country_worker_adaptive,
)


STOP=False


def utc_now() -> str:

    return datetime.now(
        timezone.utc
    ).isoformat()


def handle_signal(
    signum,
    frame,
):

    global STOP

    STOP=True

    print(
        "COUNTRY_DAEMON_SIGNAL",
        signum,
        flush=True,
    )


def main() -> int:

    signal.signal(
        signal.SIGTERM,
        handle_signal,
    )

    signal.signal(
        signal.SIGINT,
        handle_signal,
    )


    print(
        "COUNTRY_ADAPTIVE_DAEMON_START",
        "mode=adaptive",
        flush=True,
    )


    cycle=0


    while not STOP:

        cycle+=1


        decision=(
            decide_adaptive_rate()
        )


        print(
            "COUNTRY_ADAPTIVE_DECISION",
            "cycle=",
            cycle,
            "level=",
            decision.level,
            "concurrency=",
            decision.concurrency,
            "max_jobs=",
            decision.max_jobs,
            "interval=",
            decision.interval,
            "load_ratio=",
            round(
                decision.load_ratio,
                3,
            ),
            "health_runtimes=",
            decision.health_runtime_count,
            "reason=",
            decision.reason,
            flush=True,
        )


        started=time.monotonic()


        try:

            report=(
                run_country_worker_adaptive(
                    max_jobs=
                        decision.max_jobs,

                    concurrency=
                        decision.concurrency,
                )
            )


            print(
                "COUNTRY_ADAPTIVE_CYCLE",
                cycle,
                "time=",
                utc_now(),
                "eligible=",
                report.get(
                    "eligible_due"
                ),
                "selected=",
                report.get(
                    "selected"
                ),
                "processed=",
                report.get(
                    "processed"
                ),
                "concurrency=",
                report.get(
                    "concurrency"
                ),
                "states=",
                report.get(
                    "states"
                ),
                flush=True,
            )


        except RuntimeError as e:

            if str(e)==(
                "country_worker_already_running"
            ):

                print(
                    "COUNTRY_ADAPTIVE_LOCKED",
                    cycle,
                    flush=True,
                )

            else:

                print(
                    "COUNTRY_CYCLE_RUNTIME_ERROR",
                    cycle,
                    repr(e),
                    flush=True,
                )


        except Exception as e:

            print(
                "COUNTRY_CYCLE_ERROR",
                cycle,
                type(e).__name__,
                str(e)[:500],
                flush=True,
            )

            traceback.print_exc()


        elapsed=(
            time.monotonic()
            - started
        )

        wait=max(
            0.0,
            decision.interval
            - elapsed,
        )


        end=(
            time.monotonic()
            + wait
        )


        while (
            not STOP
            and
            time.monotonic()
            < end
        ):

            time.sleep(
                min(
                    0.5,
                    end
                    - time.monotonic(),
                )
            )


    print(
        "COUNTRY_ADAPTIVE_DAEMON_STOP",
        "cycles=",
        cycle,
        flush=True,
    )

    return 0


if __name__=="__main__":

    raise SystemExit(
        main()
    )
PY


echo "=== 4. COMPILE ==="

"$PY" -m py_compile \
"$M/adaptive.py" \
"$M/worker.py" \
"$M/daemon.py" \
"$M/pipeline.py"

echo "COMPILE=PASS"


echo "=== 5. ADAPTIVE DECISION SELFTEST ==="

PYTHONPATH="$R" "$PY" <<'PY'
from app.country.adaptive import (
    decide_adaptive_rate,
)

r=decide_adaptive_rate()

print(
    "LEVEL=",
    r.level,
)

print(
    "CPU=",
    r.cpu_count,
)

print(
    "LOAD1=",
    r.load1,
)

print(
    "LOAD_RATIO=",
    r.load_ratio,
)

print(
    "HEALTH_RUNTIMES=",
    r.health_runtime_count,
)

print(
    "COUNTRY_RUNTIMES=",
    r.country_runtime_count,
)

print(
    "CONCURRENCY=",
    r.concurrency,
)

print(
    "MAX_JOBS=",
    r.max_jobs,
)

print(
    "INTERVAL=",
    r.interval,
)

assert (
    1
    <= r.concurrency
    <= 6
)

assert (
    1
    <= r.max_jobs
    <= 18
)

assert (
    4
    <= r.interval
    <= 30
)

print(
    "ADAPTIVE_DECISION=PASS"
)
PY


echo "=== 6. REMOVE FIXED RATE FROM SYSTEMD ==="

sed -i \
'/^Environment=COUNTRY_MAX_JOBS_PER_CYCLE=/d' \
"$UNIT"

sed -i \
'/^Environment=COUNTRY_CYCLE_INTERVAL=/d' \
"$UNIT"

systemctl daemon-reload

systemd-analyze verify \
"$UNIT" >/dev/null

echo "FIXED_RATE_REMOVED=PASS"


echo "=== 7. RESTART ADAPTIVE COUNTRY WORKER ==="

systemctl restart \
config-location-country-worker.service

sleep 5

test "$(
    systemctl is-active \
    config-location-country-worker.service
)" = active

test "$(
    systemctl is-enabled \
    config-location-country-worker.service
)" = enabled

echo "ADAPTIVE_WORKER_STARTED=PASS"


echo "=== 8. 3-MINUTE ADAPTIVE PROOF ==="

sleep 180


echo "=== 9. JOURNAL ==="

journalctl \
-u config-location-country-worker.service \
--since "-4 minutes" \
--no-pager \
| tail -n 240


echo "=== 10. ADAPTIVE ACTIVITY VERIFY ==="

DECISIONS=$(
    journalctl \
    -u config-location-country-worker.service \
    --since "-4 minutes" \
    --no-pager \
    | grep -c \
    'COUNTRY_ADAPTIVE_DECISION' \
    || true
)

CYCLES=$(
    journalctl \
    -u config-location-country-worker.service \
    --since "-4 minutes" \
    --no-pager \
    | grep -c \
    'COUNTRY_ADAPTIVE_CYCLE' \
    || true
)

echo "ADAPTIVE_DECISIONS=$DECISIONS"
echo "ADAPTIVE_CYCLES=$CYCLES"

test "$DECISIONS" -ge 3
test "$CYCLES" -ge 3

echo "ADAPTIVE_ACTIVITY=PASS"


echo "=== 11. LAST WORKER REPORT ==="

"$PY" <<'PY'
from pathlib import Path
import json

p=Path(
    "/var/lib/config-location/"
    "country/worker/last-run.json"
)

o=json.loads(
    p.read_text()
)

print(
    json.dumps(
        {
            "mode":
                o.get("mode"),

            "eligible_due":
                o.get("eligible_due"),

            "selected":
                o.get("selected"),

            "processed":
                o.get("processed"),

            "concurrency":
                o.get("concurrency"),

            "states":
                o.get("states"),
        },
        indent=2,
    )
)

assert (
    o.get("mode")
    == "adaptive"
)

assert (
    int(
        o.get(
            "concurrency",
            0,
        )
    )
    >= 1
)

print(
    "ADAPTIVE_REPORT=PASS"
)
PY


echo "=== 12. HEALTH PRIORITY / ISOLATION ==="

for svc in \
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

echo "HEALTH_PRIORITY_ISOLATION=PASS"


echo "=== 13. RESTART / ERROR CHECK ==="

RESTARTS=$(
    systemctl show \
    config-location-country-worker.service \
    -p NRestarts \
    --value
)

echo "COUNTRY_RESTARTS=$RESTARTS"

test "$RESTARTS" -eq 0


ERRORS=$(
    journalctl \
    -u config-location-country-worker.service \
    --since "-4 minutes" \
    --no-pager \
    | grep -Ec \
    'Traceback|COUNTRY_CYCLE_ERROR|COUNTRY_CYCLE_RUNTIME_ERROR' \
    || true
)

echo "COUNTRY_ERRORS=$ERRORS"

test "$ERRORS" -eq 0


echo "=== 14. SANDBOX SLA ==="

COUNT=$(
    find \
    /var/lib/config-location/health-sandboxes \
    -maxdepth 1 \
    -type d \
    -name "country-*" \
    2>/dev/null \
    | wc -l
)

echo "COUNTRY_SANDBOXES=$COUNT"

# During adaptive parallel processing there may be
# multiple legitimate active sandboxes.
test "$COUNT" -le 6

echo "SANDBOX_SLA=PASS"


echo "=== 15. ONE-TIME CONTRACT STILL ACTIVE ==="

PYTHONPATH="$R" "$PY" <<'PY'
from collections import Counter

from app.country.worker import (
    healthy_candidates,
    country_state,
)

rows=healthy_candidates()

states=Counter(
    country_state(cid)
    for _,cid,_,_
    in rows
)

print(
    "DUE_STATES=",
    dict(states),
)

assert (
    states.get(
        "confirmed_stable",
        0,
    )
    == 0
)

assert (
    states.get(
        "confirmed_rotating_ip",
        0,
    )
    == 0
)

print(
    "CONFIRMED_RETEST_BLOCK=PASS"
)
PY


echo "=== 16. SAFETY FREEZE ==="

"$PY" <<'PY'
import json
from pathlib import Path

o=json.loads(
    Path(
        "/var/lib/config-location/"
        "country/worker-safety.json"
    ).read_text()
)

assert o[
    "publication_enabled"
] is False

assert o[
    "remark_mutation_enabled"
] is False

assert o[
    "subscription_mutation_enabled"
] is False

assert o[
    "source_raw_mutation_enabled"
] is False

print(
    "SAFETY_FREEZE=PASS"
)
PY


echo "========================================"
echo "FIX22H6=PASS"
echo "COUNTRY_THROUGHPUT=ADAPTIVE"
echo "FIXED_RATE=REMOVED"
echo "HEALTH_PRIORITY=HIGHEST"
echo "COUNTRY_CONCURRENCY=SMART"
echo "COUNTRY_BATCH_SIZE=SMART"
echo "COUNTRY_INTERVAL=SMART"
echo "SERVER_LOAD_BACKPRESSURE=ENABLED"
echo "HEALTH_RUNTIME_BACKPRESSURE=ENABLED"
echo "COUNTRY_CONFIRMED=ONE_TIME_ONLY"
echo "UNRESOLVED_RETRY=ENABLED"
echo "PUBLICATION=DISABLED"
echo "SOURCE_RAW_UNCHANGED=YES"
echo "BACKUP=$B"
echo "========================================"
