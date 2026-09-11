#!/usr/bin/env bash
set -Eeu

PHASE="phase3-pass3-permanent-retest-scheduler"

PROJECT="/opt/config-location"
REPO="/root/project-log"

SERVICE="config-location-retest.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE"

RUNTIME_DIR="/run/config-location-retest"
STATE_DIR="/var/lib/config-location/retest"
STATUS_FILE="$STATE_DIR/status.json"

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

    echo
    echo "========== FINAL =========="
    echo "RESULT=$RESULT"
    echo "END=$(date -Is)"

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

Status:
$STATUS_FILE

Observation:
$OBSERVE

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
echo " PHASE 3 PASS 3"
echo " PERMANENT RETEST SCHEDULER SERVICE"
echo "================================================"

echo "START=$START"
echo "HOST=$(hostname)"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/12] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

test -f \
"$PROJECT/app/health/retest/privileged_plan.py" || {
    fail "pass2c eligibility adapter missing"
    exit 1
}

test -f \
"$PROJECT/app/health/core/engine.py" || {
    fail "health engine missing"
    exit 1
}

test -f \
"$PROJECT/app/health/storage/json_store.py" || {
    fail "health store missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/12] BACKUP =========="

if [ -f "$SERVICE_FILE" ]; then
    cp -a \
      "$SERVICE_FILE" \
      "$BACKUP_DIR/retest.service.before"
fi

if [ -f \
"$PROJECT/app/health/retest/worker.py" ]; then

    cp -a \
      "$PROJECT/app/health/retest/worker.py" \
      "$BACKUP_DIR/worker.py.before"
fi

if [ -f "$STATUS_FILE" ]; then
    cp -a \
      "$STATUS_FILE" \
      "$BACKUP_DIR/status.json.before"
fi

echo "BACKUP_OK"


################################################
# 3 DIRECTORIES
################################################

echo
echo "========== [3/12] RUNTIME DIRECTORIES =========="

mkdir -p \
  "$RUNTIME_DIR" \
  "$STATE_DIR"

chmod 700 \
  "$RUNTIME_DIR" \
  "$STATE_DIR"

chown root:root \
  "$RUNTIME_DIR" \
  "$STATE_DIR"

echo "DIRECTORIES_OK"


################################################
# 4 INSTALL WORKER
################################################

echo
echo "========== [4/12] INSTALL WORKER =========="

cat > \
"$PROJECT/app/health/retest/worker.py" <<'PY'
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

from app.health.core.engine import (
    run_health_once,
)

from app.health.core.production_scheduler import (
    discover_jobs,
)

from app.health.storage.json_store import (
    JsonHealthResultStore,
)


PROJECT = Path("/opt/config-location")

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
    "/run/config-location-retest/"
    "worker.lock"
)


# Conservative Production caps.
#
# Interval itself is NOT hard-coded:
# it always comes live from Central Settings.
MAX_BATCH_PER_CYCLE = 3

IDLE_SLEEP_SECONDS = 30

BETWEEN_TEST_SECONDS = 2

ERROR_SLEEP_SECONDS = 15


_shutdown = False


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat()
    )


def _signal(
    signum,
    frame,
) -> None:

    global _shutdown
    _shutdown = True


signal.signal(
    signal.SIGTERM,
    _signal,
)

signal.signal(
    signal.SIGINT,
    _signal,
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
        )
        + "\n",
        encoding="utf-8",
    )

    os.chmod(
        tmp,
        0o600,
    )

    os.replace(
        tmp,
        path,
    )


def write_status(
    **kwargs,
) -> None:

    old: dict[str, Any] = {}

    try:
        if STATUS.exists():
            old = json.loads(
                STATUS.read_text(
                    encoding="utf-8"
                )
            )
    except Exception:
        old = {}

    old.update(kwargs)

    old[
        "updated_at"
    ] = utc_now()

    old[
        "pid"
    ] = os.getpid()

    atomic_json(
        STATUS,
        old,
    )


def main() -> int:

    STATE_ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )

    LOCK_PATH.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    lock_fd = os.open(
        LOCK_PATH,
        os.O_CREAT
        | os.O_RDWR,
        0o600,
    )

    try:
        fcntl.flock(
            lock_fd,
            fcntl.LOCK_EX
            | fcntl.LOCK_NB,
        )
    except BlockingIOError:

        write_status(
            state="blocked",
            reason="worker_already_running",
        )

        return 2


    store = JsonHealthResultStore(
        HEALTH_ROOT
    )


    cycle = 0
    total_tests = 0
    total_healthy = 0
    total_unhealthy = 0
    total_errors = 0


    write_status(
        component="retest-worker",
        state="starting",
        cycle=0,
        max_batch_per_cycle=(
            MAX_BATCH_PER_CYCLE
        ),
        idle_sleep_seconds=(
            IDLE_SLEEP_SECONDS
        ),
        total_tests=0,
        total_healthy=0,
        total_unhealthy=0,
        total_errors=0,
    )


    while not _shutdown:

        cycle += 1

        cycle_started = time.time()

        try:

            plan = (
                build_privileged_retest_plan(
                    limit=(
                        MAX_BATCH_PER_CYCLE
                    )
                )
            )


            jobs = discover_jobs(
                CONFIG_ROOT
            )

            job_map = {
                job.config_id: job
                for job in jobs
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

                if job is None:
                    continue

                selected.append(
                    (
                        candidate,
                        job,
                    )
                )


            write_status(
                state="running",
                cycle=cycle,
                cycle_started_at=(
                    utc_now()
                ),
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
                current_config_id=None,
                last_error=None,
            )


            cycle_results = []


            for (
                candidate,
                job,
            ) in selected:

                if _shutdown:
                    break


                cid = job.config_id


                write_status(
                    state="testing",
                    current_config_id=cid,
                    current_config_type=(
                        job.config_type
                    ),
                    current_test_started_at=(
                        utc_now()
                    ),
                )


                before_path = (
                    HEALTH_ROOT
                    / "latest"
                    / f"{cid}.json"
                )


                before_state = None
                before_finished = None

                try:
                    before = json.loads(
                        before_path.read_text(
                            encoding="utf-8"
                        )
                    )

                    before_state = (
                        before.get(
                            "state"
                        )
                    )

                    before_finished = (
                        before.get(
                            "finished_at"
                        )
                    )

                except Exception:
                    pass


                test_started = time.time()


                try:

                    result = run_health_once(
                        config_id=(
                            job.config_id
                        ),
                        config_type=(
                            job.config_type
                        ),
                        source=(
                            job.source
                        ),
                    )


                    store.save(
                        result
                    )


                    elapsed = (
                        time.time()
                        - test_started
                    )


                    total_tests += 1


                    if result.healthy:
                        total_healthy += 1
                    else:
                        total_unhealthy += 1


                    row = {
                        "config_id":
                            cid,

                        "config_type":
                            job.config_type,

                        "before_state":
                            before_state,

                        "before_finished_at":
                            before_finished,

                        "after_state":
                            result.state.value,

                        "after_finished_at":
                            result.finished_at,

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

                        "elapsed_seconds":
                            round(
                                elapsed,
                                3,
                            ),
                    }


                    cycle_results.append(
                        row
                    )


                    write_status(
                        state="running",
                        current_config_id=None,
                        last_result=row,
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
                    )


                except Exception as exc:

                    total_errors += 1

                    row = {
                        "config_id":
                            cid,

                        "config_type":
                            job.config_type,

                        "exception":
                            repr(exc),

                        "traceback":
                            traceback.format_exc()[
                                -4000:
                            ],
                    }

                    cycle_results.append(
                        row
                    )

                    write_status(
                        state="error",
                        current_config_id=None,
                        last_error=row,
                        total_errors=(
                            total_errors
                        ),
                    )


                if (
                    not _shutdown
                    and BETWEEN_TEST_SECONDS
                    > 0
                ):
                    time.sleep(
                        BETWEEN_TEST_SECONDS
                    )


            cycle_elapsed = (
                time.time()
                - cycle_started
            )


            write_status(
                state=(
                    "stopping"
                    if _shutdown
                    else "idle"
                ),
                cycle=cycle,
                cycle_finished_at=(
                    utc_now()
                ),
                cycle_elapsed_seconds=(
                    round(
                        cycle_elapsed,
                        3,
                    )
                ),
                current_config_id=None,
                cycle_results=(
                    cycle_results[
                        -MAX_BATCH_PER_CYCLE:
                    ]
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
            )


            if _shutdown:
                break


            # Sleep in one-second increments so
            # systemctl stop reacts promptly.
            for _ in range(
                IDLE_SLEEP_SECONDS
            ):

                if _shutdown:
                    break

                time.sleep(1)


        except Exception as exc:

            total_errors += 1

            write_status(
                state="cycle_error",
                cycle=cycle,
                last_error={
                    "exception":
                        repr(exc),

                    "traceback":
                        traceback.format_exc()[
                            -5000:
                        ],
                },
                total_errors=(
                    total_errors
                ),
            )


            for _ in range(
                ERROR_SLEEP_SECONDS
            ):

                if _shutdown:
                    break

                time.sleep(1)


    write_status(
        state="stopped",
        stopped_at=utc_now(),
        current_config_id=None,
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(
        main()
    )
PY

echo "WORKER_INSTALLED"


################################################
# 5 COMPILE
################################################

echo
echo "========== [5/12] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/health/retest/privileged_plan.py \
  app/health/retest/worker.py \
  app/health/core/engine.py \
  app/health/storage/json_store.py

echo "COMPILE_OK"


################################################
# 6 IMPORT TEST
################################################

echo
echo "========== [6/12] IMPORT TEST =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.retest.worker import main
from app.health.retest import (
    build_privileged_retest_plan,
)

assert callable(main)
assert callable(
    build_privileged_retest_plan
)

plan = build_privileged_retest_plan(
    limit=1
)

assert (
    plan["scanned_records"]
    > 0
)

print("IMPORT_TEST_OK")
print(
    "RETEST_MINUTES=",
    plan["retest_minutes"],
)
print(
    "DUE_TOTAL=",
    plan["due_total"],
)
PY


################################################
# 7 SYSTEMD SERVICE
################################################

echo
echo "========== [7/12] SYSTEMD SERVICE =========="

cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Config Location Permanent Health Retest Scheduler
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root

WorkingDirectory=$PROJECT

Environment=PYTHONPATH=$PROJECT
Environment=PYTHONUNBUFFERED=1

ExecStart=$PROJECT/venv/bin/python -m app.health.retest.worker

Restart=always
RestartSec=5

TimeoutStopSec=30
KillSignal=SIGTERM

Nice=5

NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE

chmod 644 "$SERVICE_FILE"

systemctl daemon-reload

echo "SYSTEMD_SERVICE_READY"


################################################
# 8 ENABLE + START
################################################

echo
echo "========== [8/12] ENABLE + START =========="

systemctl enable "$SERVICE"

systemctl restart "$SERVICE"

READY=0

for i in $(seq 1 20); do

    ACTIVE="$(
        systemctl is-active \
        "$SERVICE" \
        2>/dev/null || true
    )"

    echo "CHECK_$i ACTIVE=$ACTIVE"

    if [ "$ACTIVE" = "active" ]; then
        READY=1
        break
    fi

    sleep 1
done

if [ "$READY" -ne 1 ]; then

    journalctl \
      -u "$SERVICE" \
      --since "$START" \
      --no-pager \
      || true

    fail "retest service failed to start"
    exit 1
fi

echo "SERVICE_ACTIVE"


################################################
# 9 OBSERVE FIRST CYCLE
################################################

echo
echo "========== [9/12] OBSERVE FIRST CYCLE =========="

OBSERVED=0

for i in $(seq 1 60); do

    if [ -f "$STATUS_FILE" ]; then

        TESTS="$(
          "$PROJECT/venv/bin/python" \
          - "$STATUS_FILE" <<'PY'
import json
import sys

try:
    d=json.load(open(sys.argv[1]))
    print(int(d.get("total_tests",0)))
except Exception:
    print(0)
PY
        )"

        STATE="$(
          "$PROJECT/venv/bin/python" \
          - "$STATUS_FILE" <<'PY'
import json
import sys

try:
    d=json.load(open(sys.argv[1]))
    print(d.get("state","unknown"))
except Exception:
    print("unknown")
PY
        )"

        echo \
        "OBSERVE_$i STATE=$STATE TESTS=$TESTS"

        if [ "$TESTS" -ge 1 ]; then
            OBSERVED=1
            break
        fi
    fi

    sleep 1
done

if [ "$OBSERVED" -ne 1 ]; then

    echo "No completed test observed in 60 seconds."

    cat "$STATUS_FILE" \
      2>/dev/null || true

    journalctl \
      -u "$SERVICE" \
      --since "$START" \
      --no-pager \
      | tail -n 150 \
      || true

    fail "permanent worker did not complete a retest"
    exit 1
fi

echo "FIRST_REAL_RETEST_OBSERVED"


################################################
# 10 STATUS VALIDATION
################################################

echo
echo "========== [10/12] STATUS VALIDATION =========="

"$PROJECT/venv/bin/python" \
- "$STATUS_FILE" "$OBSERVE" <<'PY'
import json
import sys

src=sys.argv[1]
dst=sys.argv[2]

data=json.load(
    open(
        src,
        encoding="utf-8",
    )
)

assert (
    data.get(
        "component"
    )
    == "retest-worker"
)

assert (
    int(
        data.get(
            "total_tests",
            0,
        )
    )
    >= 1
)

assert (
    int(
        data.get(
            "max_batch_per_cycle",
            0,
        )
    )
    == 3
)

with open(
    dst,
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        data,
        fh,
        indent=2,
        ensure_ascii=False,
    )

    fh.write("\n")


print("STATUS_VALID")

for key in (
    "state",
    "cycle",
    "retest_minutes",
    "real_healthy",
    "due_total",
    "selected_count",
    "total_tests",
    "total_healthy",
    "total_unhealthy",
    "total_errors",
):
    print(
        key.upper(),
        "=",
        data.get(key),
    )
PY


################################################
# 11 SERVICE/JOURNAL HEALTH
################################################

echo
echo "========== [11/12] SERVICE HEALTH =========="

systemctl is-active "$SERVICE"

systemctl is-enabled "$SERVICE"

systemctl status \
  "$SERVICE" \
  --no-pager \
  -l \
  | head -n 60

FATAL="$(
    journalctl \
      -u "$SERVICE" \
      --since "$START" \
      --no-pager \
      2>/dev/null \
    | grep -Ei \
      'Traceback|SyntaxError|PermissionError|ModuleNotFoundError|segmentation fault|fatal' \
      || true
)"

if [ -n "$FATAL" ]; then

    echo "$FATAL"

    fail "fatal error detected in retest service"
    exit 1
fi

echo "SERVICE_JOURNAL_OK"


################################################
# 12 SAFETY
################################################

echo
echo "========== [12/12] SAFETY =========="

echo "PERMANENT_SERVICE=ACTIVE"
echo "BOOT_ENABLE=YES"

echo "RETEST_INTERVAL_SOURCE=CENTRAL_SETTINGS"

echo "MAX_BATCH_PER_CYCLE=3"
echo "CONCURRENCY=1"

echo "BETWEEN_TEST_SECONDS=2"
echo "IDLE_SLEEP_SECONDS=30"

echo "DEDICATED_LOCK=YES"

echo "CANONICAL_HEALTH_ENGINE=YES"
echo "CANONICAL_HEALTH_STORE=YES"

echo "MANUAL_CONFIG_DELETE=NO"

echo "EXISTING_HEALTH_SERVICE_MODIFIED=NO"
echo "PANEL_SERVICE_MODIFIED=NO"

echo
echo "PHASE3_PASS3_SUCCESS"

RESULT="SUCCESS"
