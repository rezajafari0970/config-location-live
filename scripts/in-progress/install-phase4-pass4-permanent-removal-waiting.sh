#!/usr/bin/env bash
set -Eeu

PHASE="phase4-pass4-permanent-safety-removal-waiting"

PROJECT="/opt/config-location"
REPO="/root/project-log"

SERVICE="config-location-removal-wait.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE"

WORKER="$PROJECT/app/health/lifecycle/removal_wait_worker.py"

STATE="/var/lib/config-location/health-lifecycle"
WAIT_STATE="/var/lib/config-location/removal-wait"

STATUS="$WAIT_STATE/status.json"
LOCK="/run/config-location-removal-wait/worker.lock"

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
PERMANENT SHADOW-ONLY WAITING

Production delete:
DISABLED

Config deletion:
NEVER

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
echo " PHASE 4 PASS 4"
echo " PERMANENT SAFETY / REMOVAL WAITING"
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
"$PROJECT/app/health/lifecycle/safety_gates.py" || {
    fail "safety_gates missing"
    exit 1
}

test -f \
"$PROJECT/app/health/lifecycle/policy.py" || {
    fail "policy missing"
    exit 1
}

test -f \
"$PROJECT/app/health/lifecycle/consecutive.py" || {
    fail "consecutive tracker missing"
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
  "$BACKUP_DIR/removal_wait_worker.py.before"

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
# 3 STATE DIRECTORIES
################################################

echo
echo "========== [3/10] STATE DIRECTORIES =========="

mkdir -p \
  "$WAIT_STATE" \
  /run/config-location-removal-wait

chown root:configloc "$WAIT_STATE"
chmod 750 "$WAIT_STATE"

chown root:root \
  /run/config-location-removal-wait

chmod 700 \
  /run/config-location-removal-wait

echo "STATE_READY"


################################################
# 4 INSTALL WORKER
################################################

echo
echo "========== [4/10] INSTALL WORKER =========="

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

from app.health.lifecycle.safety_gates import (
    build_safety_snapshot,
    write_snapshot,
)


CONFIG_ROOT = Path(
    "/var/lib/config-location/configs"
)

HEALTH_ROOT = Path(
    "/var/lib/config-location/health-results/latest"
)

LIFECYCLE_ROOT = Path(
    "/var/lib/config-location/health-lifecycle"
)

POLICY_PATH = (
    LIFECYCLE_ROOT / "policy-latest.json"
)

TRACKER_PATH = (
    LIFECYCLE_ROOT / "consecutive-state.json"
)

WAIT_ROOT = Path(
    "/var/lib/config-location/removal-wait"
)

STATUS_PATH = (
    WAIT_ROOT / "status.json"
)

LOCK_PATH = Path(
    "/run/config-location-removal-wait/"
    "worker.lock"
)


# Permanent waiting scheduler.
#
# Intentionally conservative.
CYCLE_SECONDS = 60

# Never perform destructive enforcement.
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


def index_records(
    value: Any,
) -> dict[str,dict[str,Any]]:

    best={}

    def walk(obj):

        if isinstance(obj,dict):

            cid=obj.get(
                "config_id"
            )

            if cid:

                cid=str(cid)

                score=sum(
                    1
                    for key in (
                        "consecutive_unhealthy",
                        "consecutive_healthy",
                        "last_result_state",
                        "policy_state",
                        "delete_candidate_shadow",
                    )
                    if key in obj
                )

                old=best.get(cid)

                if (
                    old is None
                    or score > old[0]
                ):
                    best[cid]=(
                        score,
                        obj,
                    )

            for child in obj.values():
                walk(child)

        elif isinstance(obj,list):

            for child in obj:
                walk(child)

    walk(value)

    return {
        cid:record
        for cid,(_,record)
        in best.items()
    }


def candidate_rows(
    snapshot: dict[str,Any],
) -> list[dict[str,Any]]:

    policy_index=index_records(
        read_json(
            POLICY_PATH
        )
    )

    tracker_index=index_records(
        read_json(
            TRACKER_PATH
        )
    )


    try:
        min_streak=int(
            snapshot.get(
                "candidate_min_consecutive_unhealthy",
                8,
            )
            or 8
        )
    except Exception:
        min_streak=8


    sample=snapshot.get(
        "future_enforcement_candidate_sample",
        [],
    )

    if not isinstance(
        sample,
        list,
    ):
        sample=[]


    rows=[]


    for candidate in sample:

        if isinstance(candidate,dict):

            cid=str(
                candidate.get(
                    "config_id",
                    "",
                )
            ).strip()

            snapshot_streak=(
                candidate.get(
                    "consecutive_unhealthy"
                )
            )

        else:

            cid=str(
                candidate
            ).strip()

            snapshot_streak=None


        if not cid:
            continue


        config_path=(
            CONFIG_ROOT
            / f"{cid}.json"
        )

        health_path=(
            HEALTH_ROOT
            / f"{cid}.json"
        )


        config_exists=(
            config_path.exists()
        )

        health_exists=(
            health_path.exists()
        )


        health=(
            read_json(
                health_path
            )
            if health_exists
            else {}
        )


        health_state=str(
            health.get(
                "state",
                "unknown",
            )
        ).lower()


        policy=policy_index.get(
            cid,
            {},
        )

        tracker=tracker_index.get(
            cid,
            {},
        )


        policy_state=str(
            policy.get(
                "policy_state",
                policy.get(
                    "state",
                    "unknown",
                ),
            )
        ).lower()


        delete_shadow=bool(
            policy.get(
                "delete_candidate_shadow",
                False,
            )
            or policy_state
            == "delete_candidate_shadow"
        )


        try:
            unhealthy_streak=int(
                tracker.get(
                    "consecutive_unhealthy",
                    0,
                )
                or 0
            )
        except Exception:
            unhealthy_streak=0


        try:
            healthy_streak=int(
                tracker.get(
                    "consecutive_healthy",
                    0,
                )
                or 0
            )
        except Exception:
            healthy_streak=0


        live_safe=(
            config_exists
            and health_exists
            and health_state=="unhealthy"
            and delete_shadow
            and unhealthy_streak >= min_streak
            and healthy_streak == 0
        )


        rows.append(
            {
                "config_id":
                    cid,

                "snapshot_streak":
                    snapshot_streak,

                "current_unhealthy_streak":
                    unhealthy_streak,

                "current_healthy_streak":
                    healthy_streak,

                "min_streak":
                    min_streak,

                "config_exists":
                    config_exists,

                "health_exists":
                    health_exists,

                "health_state":
                    health_state,

                "policy_state":
                    policy_state,

                "delete_candidate_shadow":
                    delete_shadow,

                "live_safe_candidate":
                    live_safe,

                # Hard boundary.
                "would_delete":
                    False,
            }
        )


    return rows


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

    WAIT_ROOT.mkdir(
        parents=True,
        exist_ok=True,
    )

    LOCK_PATH.parent.mkdir(
        parents=True,
        exist_ok=True,
    )


    lock_fd=os.open(
        LOCK_PATH,
        os.O_CREAT | os.O_RDWR,
        0o600,
    )


    try:

        fcntl.flock(
            lock_fd,
            fcntl.LOCK_EX
            | fcntl.LOCK_NB,
        )

    except BlockingIOError:

        atomic_json(
            STATUS_PATH,
            {
                "component":
                    "removal-wait-worker",

                "state":
                    "blocked",

                "reason":
                    "worker_already_running",

                "production_delete":
                    False,

                "updated_at":
                    now_iso(),
            },
        )

        return 2


    cycle=0

    total_cycles=0
    total_candidates_seen=0
    total_live_candidates_seen=0
    total_errors=0


    atomic_json(
        STATUS_PATH,
        {
            "component":
                "removal-wait-worker",

            "mode":
                "shadow_only_waiting",

            "state":
                "starting",

            "production_delete":
                False,

            "cycle_seconds":
                CYCLE_SECONDS,

            "hard_boundary":
                "NO_DELETE",

            "started_at":
                now_iso(),

            "pid":
                os.getpid(),
        },
    )


    while not _shutdown:

        cycle += 1
        total_cycles += 1

        started=time.time()


        try:

            # Canonical live build.
            first=build_safety_snapshot()

            # Short semantic stability check.
            time.sleep(0.2)

            second=build_safety_snapshot()


            first_count=int(
                first.get(
                    "future_enforcement_candidates",
                    0,
                )
                or 0
            )

            second_count=int(
                second.get(
                    "future_enforcement_candidates",
                    0,
                )
                or 0
            )


            stable=(
                first_count
                == second_count
            )


            # Use newest snapshot.
            snapshot=second


            # Write only through canonical
            # Safety API.
            write_snapshot(
                snapshot
            )


            rows=candidate_rows(
                snapshot
            )


            live_rows=[
                row
                for row in rows
                if row[
                    "live_safe_candidate"
                ]
            ]


            orphan_rows=[
                row
                for row in rows
                if (
                    not row[
                        "config_exists"
                    ]
                    or not row[
                        "health_exists"
                    ]
                )
            ]


            total_candidates_seen += len(
                rows
            )

            total_live_candidates_seen += len(
                live_rows
            )


            elapsed=(
                time.time()
                - started
            )


            status={
                "component":
                    "removal-wait-worker",

                "mode":
                    "shadow_only_waiting",

                "state":
                    "candidate_waiting"
                    if live_rows
                    else "idle",

                "production_delete":
                    False,

                "hard_boundary":
                    snapshot.get(
                        "hard_safety_boundary",
                        "NO_DELETE",
                    ),

                "cycle":
                    cycle,

                "cycle_seconds":
                    CYCLE_SECONDS,

                "cycle_started_at":
                    now_iso(),

                "cycle_elapsed_seconds":
                    round(
                        elapsed,
                        3,
                    ),

                "snapshot_semantically_stable":
                    stable,

                "canonical_future_candidates":
                    second_count,

                "sample_candidates":
                    len(rows),

                "live_safe_candidates":
                    len(live_rows),

                "orphan_candidates":
                    len(orphan_rows),

                "candidate_min_consecutive_unhealthy":
                    snapshot.get(
                        "candidate_min_consecutive_unhealthy"
                    ),

                "live_candidate_sample":
                    live_rows[:10],

                "orphan_candidate_sample":
                    orphan_rows[:10],

                "total_cycles":
                    total_cycles,

                "total_candidates_seen":
                    total_candidates_seen,

                "total_live_candidates_seen":
                    total_live_candidates_seen,

                "total_errors":
                    total_errors,

                "last_error":
                    None,

                "updated_at":
                    now_iso(),

                "pid":
                    os.getpid(),
            }


            atomic_json(
                STATUS_PATH,
                status,
            )


        except Exception as exc:

            total_errors += 1

            atomic_json(
                STATUS_PATH,
                {
                    "component":
                        "removal-wait-worker",

                    "mode":
                        "shadow_only_waiting",

                    "state":
                        "cycle_error",

                    "production_delete":
                        False,

                    "hard_boundary":
                        "NO_DELETE",

                    "cycle":
                        cycle,

                    "total_cycles":
                        total_cycles,

                    "total_errors":
                        total_errors,

                    "last_error": {
                        "exception":
                            repr(exc),

                        "traceback":
                            traceback.format_exc()[
                                -5000:
                            ],
                    },

                    "updated_at":
                        now_iso(),

                    "pid":
                        os.getpid(),
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

            "stopped_at":
                now_iso(),

            "production_delete":
                False,
        }
    )


    atomic_json(
        STATUS_PATH,
        current,
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(
        main()
    )
PY

echo "WORKER_INSTALLED"


################################################
# 5 COMPILE / IMPORT
################################################

echo
echo "========== [5/10] COMPILE + IMPORT =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/health/lifecycle/removal_wait_worker.py \
  app/health/lifecycle/safety_gates.py

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.lifecycle.removal_wait_worker import (
    candidate_rows,
)

from app.health.lifecycle.safety_gates import (
    build_safety_snapshot,
)

snapshot=build_safety_snapshot()

rows=candidate_rows(
    snapshot
)

assert isinstance(
    rows,
    list,
)

assert all(
    row["would_delete"] is False
    for row in rows
)

print("COMPILE_IMPORT_OK")
print(
    "CANONICAL_CANDIDATES=",
    snapshot.get(
        "future_enforcement_candidates"
    ),
)
print(
    "ROWS=",
    len(rows),
)
PY


################################################
# 6 SYSTEMD
################################################

echo
echo "========== [6/10] SYSTEMD =========="

cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Config Location Permanent Safety Removal Waiting Worker
After=network-online.target config-location-retest.service
Wants=network-online.target

[Service]
Type=simple

User=root
Group=root

WorkingDirectory=$PROJECT

Environment=PYTHONPATH=$PROJECT
Environment=PYTHONUNBUFFERED=1

ExecStart=$PROJECT/venv/bin/python -m app.health.lifecycle.removal_wait_worker

Restart=always
RestartSec=5

TimeoutStopSec=20
KillSignal=SIGTERM

Nice=8

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
# 7 WAIT FOR FIRST CYCLE
################################################

echo
echo "========== [7/10] WAIT FIRST CYCLE =========="

READY=0

for i in $(seq 1 60); do

    ACTIVE="$(
        systemctl is-active \
          "$SERVICE" \
          2>/dev/null || true
    )"

    if [ -f "$STATUS" ]; then

        STATE_VALUE="$(
        "$PROJECT/venv/bin/python" \
        - "$STATUS" <<'PY'
import json,sys

try:
    d=json.load(
        open(sys.argv[1])
    )

    print(
        d.get(
            "state",
            ""
        )
    )
except Exception:
    print("")
PY
        )"

        CYCLE="$(
        "$PROJECT/venv/bin/python" \
        - "$STATUS" <<'PY'
import json,sys

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
        )
    )
except Exception:
    print(0)
PY
        )"

    else
        STATE_VALUE=""
        CYCLE=0
    fi

    echo \
    "CHECK_$i ACTIVE=$ACTIVE STATE=$STATE_VALUE CYCLE=$CYCLE"

    if \
       [ "$ACTIVE" = "active" ] \
       && [ "$CYCLE" -ge 1 ]; then

        READY=1
        break
    fi

    sleep 1
done

[ "$READY" -eq 1 ] || {
    fail "waiting worker did not complete first cycle"
    exit 1
}

echo "FIRST_CYCLE_OK"


################################################
# 8 VALIDATE STATUS
################################################

echo
echo "========== [8/10] VALIDATE STATUS =========="

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
    == "removal-wait-worker"
)

assert (
    d["mode"]
    == "shadow_only_waiting"
)

assert (
    d["production_delete"]
    is False
)

assert (
    d["state"]
    in {
        "idle",
        "candidate_waiting",
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

for row in d.get(
    "live_candidate_sample",
    []
):
    assert (
        row["would_delete"]
        is False
    )

print("STATUS_VALID")

for key in (
    "state",
    "cycle",
    "cycle_seconds",
    "snapshot_semantically_stable",
    "canonical_future_candidates",
    "sample_candidates",
    "live_safe_candidates",
    "orphan_candidates",
    "candidate_min_consecutive_unhealthy",
    "total_cycles",
    "total_candidates_seen",
    "total_live_candidates_seen",
    "total_errors",
):
    print(
        key.upper(),
        "=",
        d.get(key),
    )

print(
    "HARD_BOUNDARY=",
    d.get(
        "hard_boundary"
    ),
)
PY


################################################
# 9 SERVICE HEALTH
################################################

echo
echo "========== [9/10] SERVICE HEALTH =========="

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
    fail "fatal waiting-worker error"
    exit 1
fi

echo "SERVICE_HEALTH_OK"


################################################
# 10 FINAL
################################################

echo
echo "========== [10/10] FINAL =========="

echo "PERMANENT_WAITING_SERVICE=ACTIVE"
echo "BOOT_ENABLED=YES"

echo "CANONICAL_SAFETY_REGENERATION=YES"
echo "LIVE_RECONCILIATION=YES"

echo "STALE_ORPHAN_ENFORCEMENT=BLOCKED"

echo "PRODUCTION_DELETE=DISABLED"
echo "DELETE_FUNCTION=NONE"
echo "CONFIG_DELETE=NO"

echo "PHASE4_PASS4_SUCCESS"

RESULT="SUCCESS"
