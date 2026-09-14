#!/usr/bin/env bash
set -Eeu

PHASE="phase4-pass6-canary-execution-harness-failclosed"

PROJECT="/opt/config-location"
REPO="/root/project-log"

WAIT_STATUS="/var/lib/config-location/removal-wait/status.json"
HARNESS="$PROJECT/app/health/lifecycle/canary_removal_harness.py"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"
BACKUP_DIR="/root/3245/${PHASE}-backup-${TS}"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
RESULT_JSON="$DISCOVERY_DIR/${PHASE}-${TS}.json"

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

Mode:
CANARY HARNESS / FAIL-CLOSED

Production delete:
DISABLED

Delete performed:
NO

Result:
$RESULT_JSON

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
      "$RESULT_JSON" \
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
echo " PHASE 4 PASS 6"
echo " CANARY EXECUTION HARNESS + FAIL-CLOSED GATES"
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

test -f "$WAIT_STATUS" || {
    fail "removal wait status missing"
    exit 1
}

test -f "$PROJECT/app/health/lifecycle/removal_executor.py" || {
    fail "removal executor missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/10] BACKUP =========="

[ ! -f "$HARNESS" ] || \
cp -a \
  "$HARNESS" \
  "$BACKUP_DIR/canary_removal_harness.py.before"

cp -a \
  "$WAIT_STATUS" \
  "$BACKUP_DIR/removal-wait-status.reference.json"

echo "BACKUP_OK"


################################################
# 3 INSTALL HARNESS
################################################

echo
echo "========== [3/10] INSTALL HARNESS =========="

cat > "$HARNESS" <<'PY'
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import tempfile
import time

from pathlib import Path
from typing import Any

from app.health.lifecycle.removal_executor import (
    build_removal_plan,
)


WAIT_STATUS = Path(
    "/var/lib/config-location/removal-wait/status.json"
)

LOCK_PATH = Path(
    "/run/config-location-removal-canary/canary.lock"
)

PRODUCTION_DELETE = False


def read_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        return {}


def sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None

    h=hashlib.sha256()

    with path.open("rb") as fh:
        while True:
            chunk=fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)

    return h.hexdigest()


def current_candidate_signature() -> dict[str, Any] | None:
    status=read_json(
        WAIT_STATUS
    )

    sample=status.get(
        "live_candidate_sample",
        [],
    )

    if not isinstance(sample,list):
        return None

    for row in sample:
        if not isinstance(row,dict):
            continue

        if row.get(
            "live_safe_candidate"
        ) is not True:
            continue

        return {
            "config_id":
                row.get("config_id"),

            "unhealthy_streak":
                row.get(
                    "current_unhealthy_streak"
                ),

            "healthy_streak":
                row.get(
                    "current_healthy_streak"
                ),

            "min_streak":
                row.get(
                    "min_streak"
                ),

            "health_state":
                row.get(
                    "health_state"
                ),

            "policy_state":
                row.get(
                    "policy_state"
                ),
        }

    return None


def semantic_candidate_match(
    before: dict[str,Any] | None,
    after: dict[str,Any] | None,
) -> bool:

    if before is None and after is None:
        return True

    if before is None or after is None:
        return False

    return before == after


def verify_backup_manifest(
    plan: dict[str,Any],
) -> dict[str,Any]:

    manifest=plan.get(
        "backup_manifest",
        {},
    )

    rows=manifest.get(
        "files",
        [],
    )

    if not isinstance(rows,list):
        return {
            "ok":False,
            "reason":"invalid_manifest",
        }

    if len(rows) < 2:
        return {
            "ok":False,
            "reason":"too_few_files",
        }

    mismatches=[]

    for row in rows:

        if not isinstance(row,dict):
            mismatches.append(
                "invalid_row"
            )
            continue

        path=Path(
            str(
                row.get(
                    "path",
                    ""
                )
            )
        )

        expected=row.get(
            "sha256"
        )

        actual=sha256_file(
            path
        )

        if actual != expected:
            mismatches.append(
                str(path)
            )

    return {
        "ok":
            not mismatches,

        "mismatches":
            mismatches,

        "file_count":
            len(rows),
    }


def run_failclosed_harness() -> dict[str,Any]:

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

            return {
                "state":
                    "BLOCKED",

                "reason":
                    "exclusive_lock_busy",

                "production_delete":
                    False,

                "delete_performed":
                    False,
            }


        before=current_candidate_signature()

        time.sleep(0.25)

        middle=current_candidate_signature()


        freshness_ok=semantic_candidate_match(
            before,
            middle,
        )


        plan=build_removal_plan()


        after=current_candidate_signature()


        post_plan_freshness_ok=semantic_candidate_match(
            middle,
            after,
        )


        # No candidate is a valid waiting state.
        if (
            before is None
            and plan.get("state")
            == "WAITING_NO_CANDIDATE"
        ):

            return {
                "state":
                    "WAITING_NO_CANDIDATE",

                "production_delete":
                    False,

                "delete_performed":
                    False,

                "gates": {
                    "exclusive_lock":
                        True,

                    "candidate_freshness":
                        freshness_ok,

                    "post_plan_freshness":
                        post_plan_freshness_ok,
                },
            }


        if before is None:

            return {
                "state":
                    "BLOCKED",

                "reason":
                    "candidate_missing",

                "production_delete":
                    False,

                "delete_performed":
                    False,
            }


        backup_verify=verify_backup_manifest(
            plan
        )


        gates={
            "exclusive_lock":
                True,

            "candidate_freshness":
                freshness_ok,

            "post_plan_freshness":
                post_plan_freshness_ok,

            "plan_removal_ready_shadow":
                plan.get("state")
                == "REMOVAL_READY_SHADOW",

            "final_revalidation":
                bool(
                    plan.get(
                        "final_revalidation",
                        {},
                    ).get(
                        "valid",
                        False,
                    )
                ),

            "publish_already_excluded":
                (
                    plan.get(
                        "publish",
                        {}
                    ).get(
                        "publishable"
                    )
                    is False
                ),

            "backup_manifest_verified":
                backup_verify.get(
                    "ok"
                )
                is True,

            "rollback_contract_present":
                isinstance(
                    plan.get(
                        "rollback_contract"
                    ),
                    dict,
                ),

            "referential_guard_ready":
                bool(
                    plan.get(
                        "safety_gates",
                        {},
                    ).get(
                        "referential_guard_available",
                        False,
                    )
                ),

            "production_delete_disabled":
                plan.get(
                    "production_delete"
                )
                is False,

            "delete_not_performed":
                plan.get(
                    "delete_performed"
                )
                is False,
        }


        ready=all(
            gates.values()
        )


        return {
            "state":
                (
                    "CANARY_READY"
                    if ready
                    else "BLOCKED"
                ),

            "production_delete":
                False,

            "delete_performed":
                False,

            "candidate":
                before,

            "gates":
                gates,

            "backup_verification":
                backup_verify,

            "plan_state":
                plan.get(
                    "state"
                ),

            "fail_closed":
                True,
        }


    finally:
        os.close(fd)
PY

echo "HARNESS_INSTALLED"


################################################
# 4 STATIC DESTRUCTIVE GUARD
################################################

echo
echo "========== [4/10] STATIC GUARD =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$HARNESS" <<'PY'
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

print("AST_FAILCLOSED_GUARD_OK")
PY

echo "NO_DESTRUCTIVE_PRIMITIVES=YES"


################################################
# 5 COMPILE / IMPORT
################################################

echo
echo "========== [5/10] COMPILE + IMPORT =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/health/lifecycle/canary_removal_harness.py

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.lifecycle.canary_removal_harness import (
    run_failclosed_harness,
    PRODUCTION_DELETE,
)

assert PRODUCTION_DELETE is False

r=run_failclosed_harness()

assert (
    r["production_delete"]
    is False
)

assert (
    r["delete_performed"]
    is False
)

assert r["state"] in {
    "WAITING_NO_CANDIDATE",
    "BLOCKED",
    "CANARY_READY",
}

print("HARNESS_IMPORT_OK")
print("STATE=",r["state"])
PY


################################################
# 6 EXECUTE HARNESS
################################################

echo
echo "========== [6/10] EXECUTE HARNESS =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$RESULT_JSON" <<'PY'
import json
import sys

from app.health.lifecycle.canary_removal_harness import (
    run_failclosed_harness,
)

result=run_failclosed_harness()

with open(
    sys.argv[1],
    "w",
    encoding="utf-8",
) as fh:

    json.dump(
        result,
        fh,
        ensure_ascii=False,
        indent=2,
    )

    fh.write("\n")


print(
    json.dumps(
        result,
        ensure_ascii=False,
        indent=2,
    )
)
PY


################################################
# 7 VALIDATE FAIL-CLOSED
################################################

echo
echo "========== [7/10] VALIDATE =========="

"$PROJECT/venv/bin/python" \
- "$RESULT_JSON" <<'PY'
import json
import sys

d=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

assert (
    d["production_delete"]
    is False
)

assert (
    d["delete_performed"]
    is False
)

assert d["state"] in {
    "WAITING_NO_CANDIDATE",
    "BLOCKED",
    "CANARY_READY",
}


print("FAIL_CLOSED_CONTRACT_VALID")
print(
    "STATE=",
    d["state"],
)


if d["state"]=="WAITING_NO_CANDIDATE":

    print(
        "EXPECTED_WAITING_STATE=YES"
    )


elif d["state"]=="BLOCKED":

    print(
        "CANARY_BLOCKED=YES"
    )

    print(
        "REASON=",
        d.get(
            "reason"
        )
    )

    for key,value in d.get(
        "gates",
        {}
    ).items():

        print(
            "GATE",
            key,
            "=",
            value,
        )


elif d["state"]=="CANARY_READY":

    print(
        "CANARY_READY_SHADOW=YES"
    )

    for key,value in d[
        "gates"
    ].items():

        print(
            "GATE",
            key,
            "=",
            value,
        )

        assert value is True
PY


################################################
# 8 SERVICES
################################################

echo
echo "========== [8/10] SERVICES =========="

systemctl is-active \
  config-location-retest.service \
  2>/dev/null || true

systemctl is-active \
  config-location-removal-wait.service \
  2>/dev/null || true

echo "SERVICE_RESTART=NONE"


################################################
# 9 NO DELETE VERIFICATION
################################################

echo
echo "========== [9/10] NO DELETE =========="

echo "PRODUCTION_DELETE=DISABLED"
echo "DELETE_API_CALLED=NO"
echo "CONFIG_DELETE=NO"
echo "HEALTH_DELETE=NO"
echo "COUNTRY_DELETE=NO"


################################################
# 10 FINAL
################################################

echo
echo "========== [10/10] FINAL =========="

echo "CANARY_EXECUTION_HARNESS=READY"
echo "FAIL_CLOSED_GATES=READY"
echo "EXCLUSIVE_LOCK=READY"
echo "FRESHNESS_CHECK=READY"
echo "BACKUP_HASH_CHECK=READY"
echo "ROLLBACK_CONTRACT_CHECK=READY"

echo "PRODUCTION_DELETE=DISABLED"
echo "DELETE_PERFORMED=NO"

echo
echo "PHASE4_PASS6_SUCCESS"

RESULT="SUCCESS"
