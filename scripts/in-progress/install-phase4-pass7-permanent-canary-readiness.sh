#!/usr/bin/env bash
set -Eeu

PHASE="phase4-pass7-permanent-canary-readiness-controller"

PROJECT="/opt/config-location"
REPO="/root/project-log"

SERVICE="config-location-canary-readiness.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE"

WORKER="$PROJECT/app/health/lifecycle/canary_readiness_controller.py"

STATE_DIR="/var/lib/config-location/canary-readiness"
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
        ERRORS="${ERRORS}\nexit code $CODE"
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
PERMANENT CANARY READINESS / FAIL-CLOSED

Production delete:
DISABLED

Delete performed:
NO

Status:
$STATUS

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
echo " PHASE 4 PASS 7"
echo " PERMANENT CANARY READINESS CONTROLLER"
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

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

test -f \
"$PROJECT/app/health/lifecycle/canary_removal_harness.py" || {
    fail "canary harness missing"
    exit 1
}

test -f \
"$PROJECT/app/health/lifecycle/removal_wait_worker.py" || {
    fail "removal wait worker missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/10] BACKUP =========="

[ ! -f "$WORKER" ] || \
cp -a \
  "$WORKER" \
  "$BACKUP_DIR/canary_readiness_controller.py.before"

[ ! -f "$SERVICE_FILE" ] || \
cp -a \
  "$SERVICE_FILE" \
  "$BACKUP_DIR/$SERVICE.before"

[ ! -f "$STATUS" ] || \
cp -a \
  "$STATUS" \
  "$BACKUP_DIR/status.before.json"

echo "BACKUP_OK"


################################################
# 3 STATE
################################################

echo
echo "========== [3/10] STATE =========="

mkdir -p \
  "$STATE_DIR" \
  /run/config-location-canary-readiness

chown root:configloc \
  "$STATE_DIR"

chmod 750 \
  "$STATE_DIR"

chmod 700 \
  /run/config-location-canary-readiness

echo "STATE_READY"


################################################
# 4 INSTALL CONTROLLER
################################################

echo
echo "========== [4/10] INSTALL CONTROLLER =========="

cat > "$WORKER" <<'PY'
from __future__ import annotations

import fcntl
import json
import os
import signal
import tempfile
import time
import traceback

from datetime import (
    datetime,
    timezone,
)

from pathlib import Path
from typing import Any

from app.health.lifecycle.canary_removal_harness import (
    run_failclosed_harness,
)


STATUS_PATH = Path(
    "/var/lib/config-location/"
    "canary-readiness/status.json"
)

LOCK_PATH = Path(
    "/run/config-location-canary-readiness/"
    "controller.lock"
)

CYCLE_SECONDS = 30

PRODUCTION_DELETE = False

_shutdown = False


def now_iso() -> str:
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


def read_json(
    path: Path,
) -> Any:

    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )

    except Exception:
        return {}


def atomic_json(
    path: Path,
    value: dict[str,Any],
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
        ) as fh:

            json.dump(
                value,
                fh,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )

            fh.write("\n")
            fh.flush()
            os.fsync(
                fh.fileno()
            )

        try:
            gid=path.parent.stat().st_gid

            os.chown(
                tmp,
                -1,
                gid,
            )
        except Exception:
            pass

        os.chmod(
            tmp,
            0o640,
        )

        os.replace(
            tmp,
            path,
        )

    finally:

        if os.path.exists(tmp):
            os.unlink(tmp)


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

    STATUS_PATH.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    LOCK_PATH.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    fd=os.open(
        LOCK_PATH,
        os.O_CREAT | os.O_RDWR,
        0o600,
    )

    try:

        try:
            fcntl.flock(
                fd,
                fcntl.LOCK_EX
                | fcntl.LOCK_NB,
            )

        except BlockingIOError:

            atomic_json(
                STATUS_PATH,
                {
                    "component":
                        "canary-readiness-controller",

                    "state":
                        "BLOCKED",

                    "reason":
                        "controller_already_running",

                    "production_delete":
                        False,

                    "delete_performed":
                        False,

                    "updated_at":
                        now_iso(),
                },
            )

            return 2


        cycle=0

        total_cycles=0
        total_waiting=0
        total_blocked=0
        total_canary_ready=0
        total_errors=0

        last_transition=None


        atomic_json(
            STATUS_PATH,
            {
                "component":
                    "canary-readiness-controller",

                "mode":
                    "permanent_fail_closed",

                "state":
                    "starting",

                "production_delete":
                    False,

                "delete_performed":
                    False,

                "cycle_seconds":
                    CYCLE_SECONDS,

                "hard_boundary":
                    "NO_DELETE",

                "pid":
                    os.getpid(),

                "started_at":
                    now_iso(),

                "updated_at":
                    now_iso(),
            },
        )


        previous_state=None


        while not _shutdown:

            cycle += 1
            total_cycles += 1

            cycle_started=time.time()


            try:

                result=run_failclosed_harness()

                state=str(
                    result.get(
                        "state",
                        "BLOCKED",
                    )
                )


                # Fail closed on any unexpected state.
                if state not in {
                    "WAITING_NO_CANDIDATE",
                    "BLOCKED",
                    "CANARY_READY",
                }:

                    state="BLOCKED"

                    result={
                        "state":
                            "BLOCKED",

                        "reason":
                            "unexpected_harness_state",

                        "production_delete":
                            False,

                        "delete_performed":
                            False,
                    }


                # Hard safety assertions.
                if (
                    result.get(
                        "production_delete"
                    )
                    is not False
                ):

                    state="BLOCKED"

                    result={
                        "state":
                            "BLOCKED",

                        "reason":
                            "production_delete_boundary_violation",

                        "production_delete":
                            False,

                        "delete_performed":
                            False,
                    }


                if (
                    result.get(
                        "delete_performed"
                    )
                    is not False
                ):

                    state="BLOCKED"

                    result={
                        "state":
                            "BLOCKED",

                        "reason":
                            "unexpected_delete_signal",

                        "production_delete":
                            False,

                        "delete_performed":
                            False,
                    }


                if state=="WAITING_NO_CANDIDATE":
                    total_waiting += 1

                elif state=="BLOCKED":
                    total_blocked += 1

                elif state=="CANARY_READY":
                    total_canary_ready += 1


                if state != previous_state:

                    last_transition={
                        "from":
                            previous_state,

                        "to":
                            state,

                        "at":
                            now_iso(),
                    }

                    previous_state=state


                elapsed=(
                    time.time()
                    - cycle_started
                )


                status={
                    "component":
                        "canary-readiness-controller",

                    "mode":
                        "permanent_fail_closed",

                    "state":
                        state,

                    "production_delete":
                        False,

                    "delete_performed":
                        False,

                    "hard_boundary":
                        "NO_DELETE",

                    "cycle":
                        cycle,

                    "cycle_seconds":
                        CYCLE_SECONDS,

                    "cycle_elapsed_seconds":
                        round(
                            elapsed,
                            3,
                        ),

                    "harness_result":
                        result,

                    "candidate":
                        result.get(
                            "candidate"
                        ),

                    "gates":
                        result.get(
                            "gates",
                            {},
                        ),

                    "reason":
                        result.get(
                            "reason"
                        ),

                    "total_cycles":
                        total_cycles,

                    "total_waiting":
                        total_waiting,

                    "total_blocked":
                        total_blocked,

                    "total_canary_ready":
                        total_canary_ready,

                    "total_errors":
                        total_errors,

                    "last_transition":
                        last_transition,

                    "last_error":
                        None,

                    "pid":
                        os.getpid(),

                    "updated_at":
                        now_iso(),
                }


                atomic_json(
                    STATUS_PATH,
                    status,
                )


            except Exception as exc:

                total_errors += 1
                total_blocked += 1

                state="BLOCKED"

                last_transition={
                    "from":
                        previous_state,

                    "to":
                        "BLOCKED",

                    "at":
                        now_iso(),
                }

                previous_state="BLOCKED"


                atomic_json(
                    STATUS_PATH,
                    {
                        "component":
                            "canary-readiness-controller",

                        "mode":
                            "permanent_fail_closed",

                        "state":
                            "BLOCKED",

                        "reason":
                            "controller_exception",

                        "production_delete":
                            False,

                        "delete_performed":
                            False,

                        "hard_boundary":
                            "NO_DELETE",

                        "cycle":
                            cycle,

                        "total_cycles":
                            total_cycles,

                        "total_waiting":
                            total_waiting,

                        "total_blocked":
                            total_blocked,

                        "total_canary_ready":
                            total_canary_ready,

                        "total_errors":
                            total_errors,

                        "last_transition":
                            last_transition,

                        "last_error": {
                            "exception":
                                repr(exc),

                            "traceback":
                                traceback.format_exc()[
                                    -5000:
                                ],
                        },

                        "pid":
                            os.getpid(),

                        "updated_at":
                            now_iso(),
                    },
                )


            sleep_interruptible(
                CYCLE_SECONDS
            )


        current=read_json(
            STATUS_PATH
        )

        if not isinstance(
            current,
            dict,
        ):
            current={}


        current.update(
            {
                "state":
                    "stopped",

                "production_delete":
                    False,

                "delete_performed":
                    False,

                "stopped_at":
                    now_iso(),

                "updated_at":
                    now_iso(),
            }
        )


        atomic_json(
            STATUS_PATH,
            current,
        )

        return 0


    finally:
        os.close(fd)


if __name__=="__main__":
    raise SystemExit(
        main()
    )
PY

echo "CONTROLLER_INSTALLED"


################################################
# 5 STATIC SAFETY + COMPILE
################################################

echo
echo "========== [5/10] STATIC SAFETY =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$WORKER" <<'PY'
import ast
import sys

tree=ast.parse(
    open(
        sys.argv[1],
        encoding="utf-8",
    ).read()
)

dangerous={
    "os.remove",
    "os.unlink",
    "shutil.rmtree",
}

found=[]

for node in ast.walk(tree):

    if not isinstance(
        node,
        ast.Call,
    ):
        continue

    fn=node.func
    name=None

    if isinstance(
        fn,
        ast.Attribute,
    ):

        if isinstance(
            fn.value,
            ast.Name,
        ):

            name=(
                f"{fn.value.id}."
                f"{fn.attr}"
            )

        elif fn.attr=="unlink":
            name="Path.unlink"

    if (
        name in dangerous
        or name=="Path.unlink"
    ):

        # The controller uses os.unlink(tmp) only to clean up
        # its own temporary atomic-write file.
        #
        # This is NOT a config/health/country deletion.
        allowed_atomic_tmp_cleanup = (
            name == "os.unlink"
            and len(node.args) == 1
            and isinstance(node.args[0], ast.Name)
            and node.args[0].id == "tmp"
        )

        if not allowed_atomic_tmp_cleanup:
            found.append(
                (
                    node.lineno,
                    name,
                )
            )


if found:

    for line,name in found:

        print(
            "DANGEROUS_CALL",
            line,
            name,
        )

    raise SystemExit(1)


print(
    "AST_CONTROLLER_GUARD_OK"
)
PY


PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/health/lifecycle/canary_readiness_controller.py \
  app/health/lifecycle/canary_removal_harness.py \
  app/health/lifecycle/removal_executor.py


PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import app.health.lifecycle.canary_readiness_controller as c

assert (
    c.PRODUCTION_DELETE
    is False
)

assert (
    c.CYCLE_SECONDS
    >= 10
)

print(
    "COMPILE_IMPORT_OK"
)
PY


################################################
# 6 SYSTEMD
################################################

echo
echo "========== [6/10] SYSTEMD =========="

cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Config Location Permanent Canary Readiness Controller
After=network-online.target config-location-removal-wait.service
Wants=network-online.target
Requires=config-location-removal-wait.service

[Service]
Type=simple

User=root
Group=root

WorkingDirectory=$PROJECT

Environment=PYTHONPATH=$PROJECT
Environment=PYTHONUNBUFFERED=1

ExecStart=$PROJECT/venv/bin/python -m app.health.lifecycle.canary_readiness_controller

Restart=always
RestartSec=5

TimeoutStopSec=20
KillSignal=SIGTERM

Nice=9

NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE

chmod 644 \
  "$SERVICE_FILE"

systemctl daemon-reload

systemctl enable \
  "$SERVICE"

systemctl restart \
  "$SERVICE"

echo "SYSTEMD_READY"


################################################
# 7 WAIT FIRST CYCLE
################################################

echo
echo "========== [7/10] FIRST CYCLE =========="

READY=0

for i in $(seq 1 60); do

    ACTIVE="$(
        systemctl is-active \
          "$SERVICE" \
          2>/dev/null || true
    )"

    CYCLE=0
    STATE_VALUE=""

    if [ -f "$STATUS" ]; then

        read -r CYCLE STATE_VALUE < <(
        "$PROJECT/venv/bin/python" \
        - "$STATUS" <<'PY'
import json
import sys

try:
    d=json.load(
        open(sys.argv[1])
    )

    print(
        int(
            d.get(
                "cycle",
                0,
            )
        ),
        d.get(
            "state",
            "",
        ),
    )

except Exception:
    print(
        0,
        "",
    )
PY
        )
    fi

    echo \
    "CHECK_$i ACTIVE=$ACTIVE CYCLE=$CYCLE STATE=$STATE_VALUE"

    if \
       [ "$ACTIVE" = "active" ] \
       && [ "$CYCLE" -ge 1 ]; then

        READY=1
        break
    fi

    sleep 1
done


[ "$READY" -eq 1 ] || {
    fail "controller first cycle timeout"
    exit 1
}

echo "FIRST_CYCLE_OK"


################################################
# 8 STATUS VALIDATION
################################################

echo
echo "========== [8/10] STATUS =========="

cp -a \
  "$STATUS" \
  "$OBSERVE"


"$PROJECT/venv/bin/python" \
- "$OBSERVE" <<'PY'
import json
import sys

d=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

assert (
    d["component"]
    == "canary-readiness-controller"
)

assert (
    d["mode"]
    == "permanent_fail_closed"
)

assert (
    d["production_delete"]
    is False
)

assert (
    d["delete_performed"]
    is False
)

assert (
    d["state"]
    in {
        "WAITING_NO_CANDIDATE",
        "BLOCKED",
        "CANARY_READY",
    }
)

assert (
    int(
        d.get(
            "cycle",
            0,
        )
    )
    >= 1
)


print(
    "STATUS_VALID"
)

for key in (
    "state",
    "cycle",
    "cycle_seconds",
    "total_cycles",
    "total_waiting",
    "total_blocked",
    "total_canary_ready",
    "total_errors",
):
    print(
        key.upper(),
        "=",
        d.get(key),
    )


print(
    "PRODUCTION_DELETE=",
    d[
        "production_delete"
    ],
)

print(
    "DELETE_PERFORMED=",
    d[
        "delete_performed"
    ],
)


print(
    "GATES=",
    json.dumps(
        d.get(
            "gates",
            {},
        ),
        ensure_ascii=False,
    ),
)
PY


################################################
# 9 SERVICES + JOURNAL
################################################

echo
echo "========== [9/10] SERVICES =========="

systemctl is-active \
  config-location-retest.service

systemctl is-active \
  config-location-removal-wait.service

systemctl is-active \
  "$SERVICE"

systemctl is-enabled \
  "$SERVICE"


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
    fail "controller fatal error"
    exit 1
fi


echo "SERVICE_HEALTH_OK"


################################################
# 10 FINAL
################################################

echo
echo "========== [10/10] FINAL =========="

echo "PERMANENT_CANARY_CONTROLLER=ACTIVE"
echo "BOOT_ENABLED=YES"

echo "WAITING_STATE_SUPPORTED=YES"
echo "BLOCKED_STATE_SUPPORTED=YES"
echo "CANARY_READY_STATE_SUPPORTED=YES"

echo "FAIL_CLOSED=YES"
echo "UNEXPECTED_STATE_BLOCKED=YES"
echo "EXCEPTION_BLOCKED=YES"

echo "PRODUCTION_DELETE=DISABLED"
echo "DELETE_FUNCTION=NONE"
echo "DELETE_PERFORMED=NO"

echo
echo "PHASE4_PASS7_SUCCESS"

RESULT="SUCCESS"
