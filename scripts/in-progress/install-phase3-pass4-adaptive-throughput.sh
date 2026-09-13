#!/usr/bin/env bash
set -Eeu

PHASE="phase3-pass4-production-observation-adaptive-throughput"

PROJECT="/opt/config-location"
REPO="/root/project-log"

SERVICE="config-location-retest.service"

WORKER="$PROJECT/app/health/retest/worker.py"

STATE_DIR="/var/lib/config-location/retest"
STATUS="$STATE_DIR/status.json"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"
BACKUP_DIR="/root/3245/${PHASE}-backup-${TS}"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
OBSERVE="$DISCOVERY_DIR/${PHASE}-${TS}.json"

mkdir -p \
  "$RUN_DIR" \
  "$REPORT_DIR" \
  "$DISCOVERY_DIR" \
  "$BACKUP_DIR"

RESULT="SUCCESS"
ERRORS=""

exec 3> >(tee -a "$LOG")
exec 1>&3 2>&1

fail() {
    RESULT="FAILED"
    ERRORS="${ERRORS}\n$1"
    echo "ERROR: $1"
}

finish() {
    CODE=$?

    if [ "$CODE" -ne 0 ]; then
        RESULT="FAILED"
        ERRORS="${ERRORS}\nscript exit code $CODE"
    fi

    cat > "$REPORT" <<REPORT
CONFIG LOCATION REPORT

Phase:
$PHASE

Result:
$RESULT

Start:
$START

End:
$(date -Is)

Service:
$SERVICE

Mode:
ADAPTIVE PRODUCTION

Concurrency:
1..3

Adaptive batch:
2..9

Observation:
$OBSERVE

Status:
$STATUS

Backup:
$BACKUP_DIR

Log:
$LOG

Errors:
$ERRORS
REPORT

    exec 1>&-
    exec 2>&-
    exec 3>&-

    sleep 1

    cd "$REPO" || exit 1

    git add \
      "$LOG" \
      "$REPORT" \
      "$OBSERVE" \
      >/dev/null 2>&1 || true

    if ! git diff --cached --quiet; then
        git commit \
          -m "Phase execution $PHASE $TS" \
          >/dev/null 2>&1 || true
    fi

    git push origin main >/dev/null 2>&1 || true

    [ "$RESULT" = "SUCCESS" ] || exit 1
}

trap finish EXIT


echo "================================================"
echo " PHASE 3 PASS 4"
echo " PRODUCTION OBSERVATION + ADAPTIVE THROUGHPUT"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/10] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

test -f "$WORKER" || {
    fail "current worker missing"
    exit 1
}

test -f "$PROJECT/app/health/core/batch.py" || {
    fail "BatchRunner missing"
    exit 1
}

test "$(systemctl is-active "$SERVICE")" = "active" || {
    fail "retest service not active"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/10] BACKUP =========="

cp -a "$WORKER" "$BACKUP_DIR/worker.py.before"

cp -a \
  /etc/systemd/system/$SERVICE \
  "$BACKUP_DIR/$SERVICE.before"

[ ! -f "$STATUS" ] || \
cp -a "$STATUS" "$BACKUP_DIR/status.json.before"

echo "BACKUP_OK"


################################################
# 3 INSTALL ADAPTIVE WORKER
################################################

echo
echo "========== [3/10] INSTALL ADAPTIVE WORKER =========="

cat > "$WORKER" <<'PY'
from __future__ import annotations

import fcntl
import json
import os
import signal
import time
import traceback

from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.health.retest import (
    build_privileged_retest_plan,
)

from app.health.core.production_scheduler import (
    discover_jobs,
)

from app.health.core.batch import (
    BatchRunner,
)

from app.health.storage.json_store import (
    JsonHealthResultStore,
)


CONFIG_ROOT = Path(
    "/var/lib/config-location/configs"
)

HEALTH_ROOT = Path(
    "/var/lib/config-location/health-results"
)

STATE_ROOT = Path(
    "/var/lib/config-location/retest"
)

STATUS = STATE_ROOT / "status.json"

LOCK_PATH = Path(
    "/run/config-location-retest/worker.lock"
)


MIN_WORKERS = 1
MAX_WORKERS = 3

MIN_BATCH = 2
MAX_BATCH = 9

LOW_IDLE = 5
NORMAL_IDLE = 15
HIGH_IDLE = 30


_shutdown = False


def now() -> str:
    return datetime.now(
        timezone.utc
    ).isoformat()


def handle_signal(
    signum,
    frame,
) -> None:

    global _shutdown
    _shutdown = True


signal.signal(
    signal.SIGTERM,
    handle_signal,
)

signal.signal(
    signal.SIGINT,
    handle_signal,
)


def atomic_json(
    path: Path,
    payload: dict[str, Any],
) -> None:

    path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    tmp = path.with_suffix(
        ".tmp"
    )

    tmp.write_text(
        json.dumps(
            payload,
            ensure_ascii=False,
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )

    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def read_status() -> dict[str, Any]:

    try:
        return json.loads(
            STATUS.read_text(
                encoding="utf-8"
            )
        )
    except Exception:
        return {}


def write_status(
    **values: Any,
) -> None:

    data = read_status()

    data.update(values)

    data["updated_at"] = now()
    data["pid"] = os.getpid()

    atomic_json(
        STATUS,
        data,
    )


def resource_snapshot() -> dict[str, Any]:

    cpu_count = max(
        os.cpu_count() or 1,
        1,
    )

    try:
        load1, load5, load15 = os.getloadavg()
    except OSError:
        load1 = load5 = load15 = 0.0

    load_ratio = (
        load1 / cpu_count
    )

    total_kb = 0
    avail_kb = 0

    try:
        for line in Path(
            "/proc/meminfo"
        ).read_text().splitlines():

            if line.startswith(
                "MemTotal:"
            ):
                total_kb = int(
                    line.split()[1]
                )

            elif line.startswith(
                "MemAvailable:"
            ):
                avail_kb = int(
                    line.split()[1]
                )
    except Exception:
        pass

    mem_available_pct = (
        (avail_kb / total_kb) * 100
        if total_kb
        else 100.0
    )

    return {
        "cpu_count":
            cpu_count,

        "load1":
            round(load1, 3),

        "load5":
            round(load5, 3),

        "load15":
            round(load15, 3),

        "load_ratio":
            round(load_ratio, 3),

        "mem_available_pct":
            round(
                mem_available_pct,
                2,
            ),
    }


def adaptive_policy(
    resource: dict[str, Any],
    due_total: int,
) -> dict[str, int]:

    load_ratio = float(
        resource[
            "load_ratio"
        ]
    )

    mem_pct = float(
        resource[
            "mem_available_pct"
        ]
    )

    # High pressure:
    # safest possible mode.
    if (
        load_ratio >= 0.85
        or mem_pct <= 20
    ):
        return {
            "workers": 1,
            "batch": 2,
            "idle": HIGH_IDLE,
        }

    # Medium pressure.
    if (
        load_ratio >= 0.55
        or mem_pct <= 35
    ):
        return {
            "workers": 1,
            "batch": 3,
            "idle": NORMAL_IDLE,
        }

    # Healthy server with large backlog.
    if due_total >= 200:
        return {
            "workers": 3,
            "batch": 9,
            "idle": LOW_IDLE,
        }

    # Normal backlog.
    if due_total >= 50:
        return {
            "workers": 2,
            "batch": 6,
            "idle": LOW_IDLE,
        }

    # Small backlog.
    return {
        "workers": 1,
        "batch": 3,
        "idle": NORMAL_IDLE,
    }


def sleep_interruptible(
    seconds: int,
) -> None:

    for _ in range(
        max(
            int(seconds),
            0,
        )
    ):
        if _shutdown:
            return

        time.sleep(1)


def main() -> int:

    STATE_ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )

    LOCK_PATH.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd = os.open(
        LOCK_PATH,
        os.O_CREAT | os.O_RDWR,
        0o600,
    )

    try:
        fcntl.flock(
            fd,
            fcntl.LOCK_EX
            | fcntl.LOCK_NB,
        )
    except BlockingIOError:

        write_status(
            state="blocked",
            reason="already_running",
        )

        return 2


    store = JsonHealthResultStore(
        HEALTH_ROOT
    )


    previous = read_status()

    cycle = int(
        previous.get(
            "cycle",
            0,
        )
        or 0
    )

    total_tests = int(
        previous.get(
            "total_tests",
            0,
        )
        or 0
    )

    total_healthy = int(
        previous.get(
            "total_healthy",
            0,
        )
        or 0
    )

    total_unhealthy = int(
        previous.get(
            "total_unhealthy",
            0,
        )
        or 0
    )

    total_errors = int(
        previous.get(
            "total_errors",
            0,
        )
        or 0
    )

    total_runtime_seconds = float(
        previous.get(
            "total_test_runtime_seconds",
            0,
        )
        or 0
    )


    write_status(
        component="retest-worker",
        mode="adaptive",
        state="starting",
        min_workers=MIN_WORKERS,
        max_workers=MAX_WORKERS,
        min_batch=MIN_BATCH,
        max_batch=MAX_BATCH,
    )


    while not _shutdown:

        cycle += 1

        cycle_start = time.time()

        try:

            # First look at due count
            # with a small plan.
            preview = (
                build_privileged_retest_plan(
                    limit=1
                )
            )

            resource = (
                resource_snapshot()
            )

            policy = adaptive_policy(
                resource,
                int(
                    preview[
                        "due_total"
                    ]
                ),
            )

            workers = max(
                MIN_WORKERS,
                min(
                    int(
                        policy[
                            "workers"
                        ]
                    ),
                    MAX_WORKERS,
                ),
            )

            batch_size = max(
                MIN_BATCH,
                min(
                    int(
                        policy[
                            "batch"
                        ]
                    ),
                    MAX_BATCH,
                ),
            )

            idle_seconds = int(
                policy["idle"]
            )


            plan = (
                build_privileged_retest_plan(
                    limit=batch_size
                )
            )


            jobs = discover_jobs(
                CONFIG_ROOT
            )

            job_map = {
                job.config_id:
                    job
                for job
                in jobs
            }


            selected = []

            for candidate in (
                plan["candidates"]
            ):

                job = job_map.get(
                    candidate[
                        "config_id"
                    ]
                )

                if job is not None:
                    selected.append(
                        job
                    )


            write_status(
                state="running",
                mode="adaptive",
                cycle=cycle,
                cycle_started_at=now(),

                retest_minutes=(
                    plan[
                        "retest_minutes"
                    ]
                ),

                scanned_records=(
                    plan[
                        "scanned_records"
                    ]
                ),

                real_healthy=(
                    plan[
                        "real_healthy"
                    ]
                ),

                due_total=(
                    plan[
                        "due_total"
                    ]
                ),

                selected_count=(
                    len(selected)
                ),

                adaptive_workers=(
                    workers
                ),

                adaptive_batch=(
                    batch_size
                ),

                adaptive_idle_seconds=(
                    idle_seconds
                ),

                resource=resource,

                last_error=None,
            )


            if not selected:

                write_status(
                    state="idle",
                    cycle_finished_at=now(),
                    selected_count=0,
                )

                sleep_interruptible(
                    idle_seconds
                )

                continue


            runner = BatchRunner(
                max_workers=workers,
                result_store=store,
            )


            batch_started = time.time()


            results, summary = (
                runner.run(
                    selected
                )
            )


            batch_elapsed = (
                time.time()
                - batch_started
            )


            cycle_completed = len(
                results
            )


            cycle_healthy = sum(
                1
                for result
                in results
                if result.healthy
            )

            cycle_unhealthy = (
                cycle_completed
                - cycle_healthy
            )


            total_tests += (
                cycle_completed
            )

            total_healthy += (
                cycle_healthy
            )

            total_unhealthy += (
                cycle_unhealthy
            )

            total_runtime_seconds += (
                batch_elapsed
            )


            avg_test_seconds = (
                total_runtime_seconds
                / total_tests
                if total_tests
                else 0.0
            )


            throughput_hour = (
                (
                    cycle_completed
                    / batch_elapsed
                )
                * 3600
                if batch_elapsed > 0
                else 0.0
            )


            healthy_rate = (
                (
                    total_healthy
                    / total_tests
                )
                * 100
                if total_tests
                else 0.0
            )


            cycle_results = []

            for result in results:
                cycle_results.append(
                    {
                        "config_id":
                            result.config_id,

                        "config_type":
                            result.config_type,

                        "state":
                            result.state.value,

                        "healthy":
                            result.healthy,

                        "xray_started":
                            result.xray_started,

                        "download_verified":
                            result.download_verified,

                        "upload_verified":
                            result.upload_verified,

                        "error_code":
                            result.error_code,

                        "finished_at":
                            result.finished_at,
                    }
                )


            write_status(
                state="idle",

                cycle_finished_at=now(),

                cycle_elapsed_seconds=round(
                    time.time()
                    - cycle_start,
                    3,
                ),

                batch_elapsed_seconds=round(
                    batch_elapsed,
                    3,
                ),

                cycle_completed=(
                    cycle_completed
                ),

                cycle_healthy=(
                    cycle_healthy
                ),

                cycle_unhealthy=(
                    cycle_unhealthy
                ),

                cycle_results=(
                    cycle_results
                ),

                total_tests=(
                    total_tests
                ),

                total_healthy=(
                    total_healthy
                ),

                total_unhealthy=(
                    total_unhealthy
                ),

                total_errors=(
                    total_errors
                ),

                total_test_runtime_seconds=round(
                    total_runtime_seconds,
                    3,
                ),

                average_test_seconds=round(
                    avg_test_seconds,
                    3,
                ),

                current_throughput_per_hour=round(
                    throughput_hour,
                    2,
                ),

                overall_healthy_rate_pct=round(
                    healthy_rate,
                    2,
                ),
            )


            sleep_interruptible(
                idle_seconds
            )


        except Exception as exc:

            total_errors += 1

            write_status(
                state="cycle_error",
                total_errors=total_errors,

                last_error={
                    "exception":
                        repr(exc),

                    "traceback":
                        traceback.format_exc()[
                            -5000:
                        ],
                },
            )

            sleep_interruptible(
                HIGH_IDLE
            )


    write_status(
        state="stopped",
        stopped_at=now(),
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY

echo "ADAPTIVE_WORKER_INSTALLED"


################################################
# 4 COMPILE
################################################

echo
echo "========== [4/10] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/health/retest/worker.py \
  app/health/core/batch.py

echo "COMPILE_OK"


################################################
# 5 IMPORT TEST
################################################

echo
echo "========== [5/10] IMPORT TEST =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.retest.worker import (
    adaptive_policy,
    resource_snapshot,
)

r=resource_snapshot()

p=adaptive_policy(
    r,
    1000,
)

assert 1 <= p["workers"] <= 3
assert 2 <= p["batch"] <= 9

print("IMPORT_OK")
print("RESOURCE=", r)
print("POLICY=", p)
PY


################################################
# 6 RESTART SERVICE
################################################

echo
echo "========== [6/10] RESTART SERVICE =========="

systemctl restart "$SERVICE"

for i in $(seq 1 20); do

    ACTIVE="$(
        systemctl is-active \
        "$SERVICE" \
        2>/dev/null || true
    )"

    echo "CHECK_$i ACTIVE=$ACTIVE"

    if [ "$ACTIVE" = "active" ]; then
        break
    fi

    sleep 1
done

test "$(systemctl is-active "$SERVICE")" = "active" || {
    fail "service did not restart"
    exit 1
}

echo "SERVICE_ACTIVE"


################################################
# 7 OBSERVE REAL ADAPTIVE CYCLE
################################################

echo
echo "========== [7/10] OBSERVATION =========="

OBSERVED=0

for i in $(seq 1 180); do

    if [ -f "$STATUS" ]; then

        MODE="$(
          "$PROJECT/venv/bin/python" \
          - "$STATUS" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(d.get("mode",""))
except Exception:
    print("")
PY
        )"

        COMPLETED="$(
          "$PROJECT/venv/bin/python" \
          - "$STATUS" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(int(d.get("cycle_completed",0)))
except Exception:
    print(0)
PY
        )"

        STATE="$(
          "$PROJECT/venv/bin/python" \
          - "$STATUS" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(d.get("state",""))
except Exception:
    print("")
PY
        )"

        echo \
        "OBSERVE_$i MODE=$MODE STATE=$STATE COMPLETED=$COMPLETED"

        if [ \
            "$MODE" = "adaptive" \
            ] && [ \
            "$COMPLETED" -ge 1 \
            ]; then

            OBSERVED=1
            break
        fi
    fi

    sleep 1
done

if [ "$OBSERVED" -ne 1 ]; then

    cat "$STATUS" 2>/dev/null || true

    journalctl \
      -u "$SERVICE" \
      --since "$START" \
      --no-pager \
      | tail -n 200 \
      || true

    fail "adaptive cycle not observed"
    exit 1
fi

echo "ADAPTIVE_CYCLE_OBSERVED"


################################################
# 8 SAVE OBSERVATION
################################################

echo
echo "========== [8/10] SAVE OBSERVATION =========="

cp -a "$STATUS" "$OBSERVE"

"$PROJECT/venv/bin/python" \
- "$OBSERVE" <<'PY'
import json
import sys

d=json.load(open(sys.argv[1]))

assert d["mode"]=="adaptive"

assert 1 <= int(
    d["adaptive_workers"]
) <= 3

assert 2 <= int(
    d["adaptive_batch"]
) <= 9

assert int(
    d.get(
        "cycle_completed",
        0,
    )
) >= 1

print("OBSERVATION_VALID")

for k in (
    "cycle",
    "retest_minutes",
    "due_total",
    "adaptive_workers",
    "adaptive_batch",
    "adaptive_idle_seconds",
    "cycle_completed",
    "cycle_healthy",
    "cycle_unhealthy",
    "total_tests",
    "total_healthy",
    "total_unhealthy",
    "total_errors",
    "average_test_seconds",
    "current_throughput_per_hour",
    "overall_healthy_rate_pct",
):
    print(
        f"{k.upper()}=",
        d.get(k),
    )

print(
    "RESOURCE=",
    d.get("resource"),
)
PY


################################################
# 9 SERVICE HEALTH
################################################

echo
echo "========== [9/10] SERVICE HEALTH =========="

systemctl is-active "$SERVICE"
systemctl is-enabled "$SERVICE"

FATAL="$(
journalctl \
  -u "$SERVICE" \
  --since "$START" \
  --no-pager \
  | grep -Ei \
  'Traceback|SyntaxError|ModuleNotFoundError|PermissionError|fatal' \
  || true
)"

if [ -n "$FATAL" ]; then
    echo "$FATAL"
    fail "fatal service log detected"
    exit 1
fi

echo "SERVICE_HEALTH_OK"


################################################
# 10 FINAL
################################################

echo
echo "========== [10/10] FINAL =========="

echo "ADAPTIVE_MODE=YES"
echo "CONCURRENCY_RANGE=1..3"
echo "BATCH_RANGE=2..9"
echo "RESOURCE_AWARE=YES"
echo "BACKLOG_AWARE=YES"

echo "CANONICAL_BATCH_RUNNER=YES"
echo "CANONICAL_HEALTH_STORE=YES"

echo "CENTRAL_SETTINGS_INTERVAL=YES"

echo "MANUAL_DELETE=NO"
echo "PANEL_MODIFIED=NO"

echo
echo "PHASE3_PASS4_SUCCESS"

RESULT="SUCCESS"
