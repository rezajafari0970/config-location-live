#!/usr/bin/env bash
set -Eeu

PHASE="phase4-final-integration-regression"

PROJECT="/opt/config-location"
REPO="/root/project-log"

WAIT_STATUS="/var/lib/config-location/removal-wait/status.json"
CANARY_STATUS="/var/lib/config-location/canary-readiness/status.json"
SAFETY="/var/lib/config-location/health-lifecycle/safety-latest.json"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
FINAL="$DISCOVERY_DIR/${PHASE}-${TS}.json"

mkdir -p \
  "$RUN_DIR" \
  "$REPORT_DIR" \
  "$DISCOVERY_DIR"

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

    echo
    echo "================================================"
    echo " FINAL RESULT"
    echo "================================================"
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

Mode:
FINAL INTEGRATION / REGRESSION

Production delete:
DISABLED

Delete performed:
NO

Final:
$FINAL

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
      "$FINAL" \
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
echo " PHASE 4 FINAL INTEGRATION / REGRESSION"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/14] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

for FILE in \
  "$PROJECT/app/health/lifecycle/engine.py" \
  "$PROJECT/app/health/lifecycle/policy.py" \
  "$PROJECT/app/health/lifecycle/consecutive.py" \
  "$PROJECT/app/health/lifecycle/safety_gates.py" \
  "$PROJECT/app/health/lifecycle/removal_wait_worker.py" \
  "$PROJECT/app/health/lifecycle/removal_executor.py" \
  "$PROJECT/app/health/lifecycle/canary_removal_harness.py" \
  "$PROJECT/app/health/lifecycle/canary_readiness_controller.py" \
  "$PROJECT/app/integrity/referential_guard.py" \
  "$PROJECT/app/publish/filter.py"
do
    test -f "$FILE" || {
        fail "missing $FILE"
        exit 1
    }
done

test -f "$WAIT_STATUS" || {
    fail "removal wait status missing"
    exit 1
}

test -f "$CANARY_STATUS" || {
    fail "canary readiness status missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 COMPILE
################################################

echo
echo "========== [2/14] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/health/lifecycle/engine.py \
  app/health/lifecycle/policy.py \
  app/health/lifecycle/consecutive.py \
  app/health/lifecycle/safety_gates.py \
  app/health/lifecycle/removal_wait_worker.py \
  app/health/lifecycle/removal_executor.py \
  app/health/lifecycle/canary_removal_harness.py \
  app/health/lifecycle/canary_readiness_controller.py \
  app/integrity/referential_guard.py \
  app/publish/filter.py

echo "COMPILE_OK"


################################################
# 3 IMPORT GRAPH
################################################

echo
echo "========== [3/14] IMPORT GRAPH =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.lifecycle.safety_gates import (
    build_safety_snapshot,
)

from app.health.lifecycle.removal_executor import (
    build_removal_plan,
    PRODUCTION_DELETE as EXECUTOR_DELETE,
)

from app.health.lifecycle.canary_removal_harness import (
    run_failclosed_harness,
    PRODUCTION_DELETE as HARNESS_DELETE,
)

from app.health.lifecycle.canary_readiness_controller import (
    PRODUCTION_DELETE as CONTROLLER_DELETE,
)

assert EXECUTOR_DELETE is False
assert HARNESS_DELETE is False
assert CONTROLLER_DELETE is False

snapshot=build_safety_snapshot()
assert isinstance(snapshot,dict)

print("IMPORT_GRAPH_OK")
print(
    "SAFETY_CANDIDATES=",
    snapshot.get("future_enforcement_candidates"),
)
PY


################################################
# 4 STATIC DESTRUCTIVE AUDIT
################################################

echo
echo "========== [4/14] DESTRUCTIVE AUDIT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import ast
from pathlib import Path

root=Path("/opt/config-location/app/health/lifecycle")

files=[
    root/"removal_executor.py",
    root/"canary_removal_harness.py",
    root/"canary_readiness_controller.py",
]

dangerous={
    "os.remove",
    "shutil.rmtree",
}

problems=[]

for path in files:

    tree=ast.parse(
        path.read_text(
            encoding="utf-8"
        )
    )

    for node in ast.walk(tree):

        if not isinstance(node,ast.Call):
            continue

        fn=node.func
        name=None

        if isinstance(fn,ast.Attribute):

            if isinstance(fn.value,ast.Name):
                name=f"{fn.value.id}.{fn.attr}"

            elif fn.attr=="unlink":
                name="Path.unlink"

        if name in dangerous or name=="Path.unlink":
            problems.append(
                (str(path),node.lineno,name)
            )

        # os.unlink(tmp) is permitted only for
        # atomic temp-file cleanup.
        if name=="os.unlink":

            allowed=(
                len(node.args)==1
                and isinstance(node.args[0],ast.Name)
                and node.args[0].id=="tmp"
            )

            if not allowed:
                problems.append(
                    (str(path),node.lineno,name)
                )

if problems:

    for item in problems:
        print("DESTRUCTIVE_PROBLEM",item)

    raise SystemExit(1)

print("DESTRUCTIVE_AUDIT_OK")
PY


################################################
# 5 SYSTEMD
################################################

echo
echo "========== [5/14] SYSTEMD =========="

SERVICES=(
  config-location-retest.service
  config-location-removal-wait.service
  config-location-canary-readiness.service
)

for SERVICE in "${SERVICES[@]}"; do

    ACTIVE="$(
        systemctl is-active \
          "$SERVICE" \
          2>/dev/null || true
    )"

    ENABLED="$(
        systemctl is-enabled \
          "$SERVICE" \
          2>/dev/null || true
    )"

    echo "$SERVICE ACTIVE=$ACTIVE ENABLED=$ENABLED"

    [ "$ACTIVE" = "active" ] || {
        fail "$SERVICE inactive"
        exit 1
    }

    [ "$ENABLED" = "enabled" ] || {
        fail "$SERVICE disabled"
        exit 1
    }

done

echo "SYSTEMD_OK"


################################################
# 6 REMOVAL-WAIT STATUS
################################################

echo
echo "========== [6/14] REMOVAL WAIT =========="

"$PROJECT/venv/bin/python" \
- "$WAIT_STATUS" <<'PY'
import json
import sys

d=json.load(open(sys.argv[1]))

assert d["component"]=="removal-wait-worker"
assert d["mode"]=="shadow_only_waiting"
assert d["production_delete"] is False

assert d["state"] in {
    "idle",
    "candidate_waiting",
}

assert int(d.get("cycle",0)) >= 1
assert int(d.get("total_errors",0)) == 0

print("REMOVAL_WAIT_OK")
print("STATE=",d["state"])
print("CYCLE=",d["cycle"])
print(
    "CANONICAL_CANDIDATES=",
    d.get("canonical_future_candidates"),
)
print(
    "LIVE_SAFE_CANDIDATES=",
    d.get("live_safe_candidates"),
)
print(
    "ORPHAN_CANDIDATES=",
    d.get("orphan_candidates"),
)
PY


################################################
# 7 CANARY CONTROLLER STATUS
################################################

echo
echo "========== [7/14] CANARY CONTROLLER =========="

"$PROJECT/venv/bin/python" \
- "$CANARY_STATUS" <<'PY'
import json
import sys

d=json.load(open(sys.argv[1]))

assert d["component"]=="canary-readiness-controller"
assert d["mode"]=="permanent_fail_closed"
assert d["production_delete"] is False
assert d["delete_performed"] is False

assert d["state"] in {
    "WAITING_NO_CANDIDATE",
    "BLOCKED",
    "CANARY_READY",
}

assert int(d.get("cycle",0)) >= 1
assert int(d.get("total_errors",0)) == 0

print("CANARY_CONTROLLER_OK")
print("STATE=",d["state"])
print("CYCLE=",d["cycle"])
print("TOTAL_WAITING=",d.get("total_waiting"))
print("TOTAL_BLOCKED=",d.get("total_blocked"))
print("TOTAL_CANARY_READY=",d.get("total_canary_ready"))
PY


################################################
# 8 LIVE HARNESS
################################################

echo
echo "========== [8/14] LIVE FAIL-CLOSED HARNESS =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.lifecycle.canary_removal_harness import (
    run_failclosed_harness,
)

r=run_failclosed_harness()

assert r["production_delete"] is False
assert r["delete_performed"] is False

assert r["state"] in {
    "WAITING_NO_CANDIDATE",
    "BLOCKED",
    "CANARY_READY",
}

print("HARNESS_OK")
print("STATE=",r["state"])

for k,v in r.get("gates",{}).items():
    print("GATE",k,"=",v)
PY


################################################
# 9 REMOVAL PLAN
################################################

echo
echo "========== [9/14] REMOVAL PLAN =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.lifecycle.removal_executor import (
    build_removal_plan,
)

p=build_removal_plan()

assert p["production_delete"] is False
assert p["delete_performed"] is False

assert p["state"] in {
    "WAITING_NO_CANDIDATE",
    "REMOVAL_READY_SHADOW",
    "REMOVAL_BLOCKED",
}

print("REMOVAL_PLAN_OK")
print("STATE=",p["state"])
PY


################################################
# 10 SAFETY STABILITY
################################################

echo
echo "========== [10/14] SAFETY STABILITY =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import time

from app.health.lifecycle.safety_gates import (
    build_safety_snapshot,
)

a=build_safety_snapshot()

time.sleep(0.25)

b=build_safety_snapshot()

ac=int(
    a.get(
        "future_enforcement_candidates",
        0,
    )
    or 0
)

bc=int(
    b.get(
        "future_enforcement_candidates",
        0,
    )
    or 0
)

assert ac == bc

print("SAFETY_STABLE_OK")
print("FIRST=",ac)
print("SECOND=",bc)
print(
    "MIN_STREAK=",
    b.get(
        "candidate_min_consecutive_unhealthy"
    ),
)
print(
    "BOUNDARY=",
    b.get("hard_safety_boundary"),
)
PY


################################################
# 11 PUBLISH ISOLATION
################################################

echo
echo "========== [11/14] PUBLISH ISOLATION =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$WAIT_STATUS" <<'PY'
import json
import sys

from app.publish.filter import (
    publishable_config_ids,
)

status=json.load(open(sys.argv[1]))

publishable=set(
    publishable_config_ids()
)

live=status.get(
    "live_candidate_sample",
    [],
)

checked=0

for row in live:

    if not isinstance(row,dict):
        continue

    if row.get(
        "live_safe_candidate"
    ) is not True:
        continue

    cid=row.get("config_id")

    assert cid not in publishable

    checked += 1

print("PUBLISH_ISOLATION_OK")
print("LIVE_CANDIDATES_CHECKED=",checked)
print("PUBLISHABLE_COUNT=",len(publishable))
PY


################################################
# 12 REFERENTIAL GUARD
################################################

echo
echo "========== [12/14] REFERENTIAL GUARD =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import inspect

import app.integrity.referential_guard as rg

for name in (
    "reconcile_one_orphan",
    "sweep_orphans",
):

    fn=getattr(rg,name,None)

    assert callable(fn)

    print(
        name,
        inspect.signature(fn),
    )

print("REFERENTIAL_GUARD_OK")
PY


################################################
# 13 JOURNAL REGRESSION
################################################

echo
echo "========== [13/14] JOURNAL =========="

FATAL="$(
journalctl \
  --since "$START" \
  --no-pager \
  -u config-location-retest.service \
  -u config-location-removal-wait.service \
  -u config-location-canary-readiness.service \
  | grep -Ei \
  'Traceback|SyntaxError|ModuleNotFoundError|PermissionError|segmentation fault|fatal' \
  || true
)"

if [ -n "$FATAL" ]; then

    echo "$FATAL"

    fail "fatal runtime error detected"
    exit 1
fi

echo "JOURNAL_OK"


################################################
# 14 FINAL SNAPSHOT
################################################

echo
echo "========== [14/14] FINAL SNAPSHOT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$WAIT_STATUS" "$CANARY_STATUS" "$FINAL" <<'PY'
import json
import sys

from datetime import (
    datetime,
    timezone,
)

from app.health.lifecycle.safety_gates import (
    build_safety_snapshot,
)

wait=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

canary=json.load(
    open(
        sys.argv[2],
        encoding="utf-8",
    )
)

safety=build_safety_snapshot()

out={
    "phase":
        "phase4-final-integration-regression",

    "result":
        "SUCCESS",

    "generated_at":
        datetime.now(
            timezone.utc
        ).isoformat(),

    "production_delete":
        False,

    "delete_performed":
        False,

    "services": {
        "retest":
            "active",

        "removal_wait":
            "active",

        "canary_readiness":
            "active",
    },

    "removal_wait": {
        "state":
            wait.get("state"),

        "cycle":
            wait.get("cycle"),

        "canonical_future_candidates":
            wait.get(
                "canonical_future_candidates"
            ),

        "live_safe_candidates":
            wait.get(
                "live_safe_candidates"
            ),

        "orphan_candidates":
            wait.get(
                "orphan_candidates"
            ),

        "total_errors":
            wait.get(
                "total_errors"
            ),
    },

    "canary_readiness": {
        "state":
            canary.get("state"),

        "cycle":
            canary.get("cycle"),

        "total_waiting":
            canary.get(
                "total_waiting"
            ),

        "total_blocked":
            canary.get(
                "total_blocked"
            ),

        "total_canary_ready":
            canary.get(
                "total_canary_ready"
            ),

        "total_errors":
            canary.get(
                "total_errors"
            ),
    },

    "safety": {
        "future_enforcement_candidates":
            safety.get(
                "future_enforcement_candidates"
            ),

        "candidate_min_consecutive_unhealthy":
            safety.get(
                "candidate_min_consecutive_unhealthy"
            ),

        "hard_safety_boundary":
            safety.get(
                "hard_safety_boundary"
            ),
    },

    "checks": {
        "precheck":
            True,

        "compile":
            True,

        "import_graph":
            True,

        "destructive_audit":
            True,

        "systemd":
            True,

        "removal_wait":
            True,

        "canary_controller":
            True,

        "fail_closed_harness":
            True,

        "removal_plan":
            True,

        "safety_stability":
            True,

        "publish_isolation":
            True,

        "referential_guard":
            True,

        "journal":
            True,
    },

    "phase4_freeze_ready":
        True,
}


with open(
    sys.argv[3],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        out,
        fh,
        ensure_ascii=False,
        indent=2,
    )

    fh.write("\n")


print(
    json.dumps(
        out,
        ensure_ascii=False,
        indent=2,
    )
)
PY


echo
echo "================================================"
echo " PHASE 4 FINAL REGRESSION: PASS"
echo "================================================"

echo "LIFECYCLE_INTEGRATION=PASS"
echo "SAFETY_INTEGRATION=PASS"
echo "REMOVAL_WAIT=PASS"
echo "CANARY_CONTROLLER=PASS"
echo "FAIL_CLOSED=PASS"
echo "PUBLISH_ISOLATION=PASS"
echo "REFERENTIAL_GUARD=PASS"
echo "RUNTIME_ERRORS=NONE"

echo "PRODUCTION_DELETE=DISABLED"
echo "DELETE_PERFORMED=NO"

echo "PHASE4_FREEZE_READY=YES"
echo "PHASE4_FINAL_SUCCESS"

RESULT="SUCCESS"
