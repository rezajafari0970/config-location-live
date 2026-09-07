#!/usr/bin/env bash
set -Eeu

PHASE="phase3-pass2d-controlled-canary-retest"

PROJECT="/opt/config-location"
REPO="/root/project-log"

CONFIG_ROOT="/var/lib/config-location/configs"
HEALTH_ROOT="/var/lib/config-location/health-results"
LATEST="$HEALTH_ROOT/latest"

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

Mode:
CONTROLLED CANARY

Canary count:
1

Manual config delete:
NONE

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
echo " PHASE 3 PASS 2D"
echo " CONTROLLED CANARY RETEST"
echo "================================================"

echo "START=$START"
echo "HOST=$(hostname)"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/9] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

test -d "$CONFIG_ROOT" || {
    fail "config store missing"
    exit 1
}

test -d "$LATEST" || {
    fail "health latest missing"
    exit 1
}

test -f "$PROJECT/app/health/retest/privileged_plan.py" || {
    fail "pass2c adapter missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 LOCK
################################################

echo
echo "========== [2/9] CANARY LOCK =========="

exec 9>/run/config-location-retest-canary.lock

if ! flock -n 9; then
    fail "another canary retest is running"
    exit 1
fi

echo "CANARY_LOCK_ACQUIRED"


################################################
# 3 COMPILE
################################################

echo
echo "========== [3/9] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/health/core/engine.py \
  app/health/core/production_scheduler.py \
  app/health/storage/json_store.py \
  app/health/retest/privileged_plan.py \
  app/publish/filter.py

echo "COMPILE_OK"


################################################
# 4 CREATE CANARY RUNNER
################################################

echo
echo "========== [4/9] CANARY RUNNER =========="

cat > /root/phase3-pass2d-canary.py <<'PY'
from __future__ import annotations

import hashlib
import json
import shutil
import time
from pathlib import Path

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

from app.publish.filter import (
    publishable_config_ids,
)


CONFIG_ROOT = Path(
    "/var/lib/config-location/configs"
)

HEALTH_ROOT = Path(
    "/var/lib/config-location/health-results"
)

BACKUP_ROOT = Path(
    "__BACKUP_DIR__"
)

OUTPUT = Path(
    "__RESULT_JSON__"
)


def sha256(path: Path) -> str | None:
    if not path.exists():
        return None

    h = hashlib.sha256()

    with path.open("rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)

            if not chunk:
                break

            h.update(chunk)

    return h.hexdigest()


plan = build_privileged_retest_plan(
    limit=50
)

if not plan["candidates"]:
    raise RuntimeError(
        "no due healthy candidates"
    )


jobs = discover_jobs(
    CONFIG_ROOT
)

job_map = {
    job.config_id: job
    for job in jobs
}


selected = None
job = None

for candidate in plan["candidates"]:
    candidate_job = job_map.get(
        candidate["config_id"]
    )

    if candidate_job is None:
        continue

    selected = candidate
    job = candidate_job
    break


if selected is None or job is None:
    raise RuntimeError(
        "no due candidate matched canonical config store"
    )


cid = selected["config_id"]

latest_path = (
    HEALTH_ROOT
    / "latest"
    / f"{cid}.json"
)


before_payload = json.loads(
    latest_path.read_text(
        encoding="utf-8"
    )
)

before_hash = sha256(
    latest_path
)

before_mtime = (
    latest_path.stat().st_mtime_ns
)

BACKUP_ROOT.mkdir(
    parents=True,
    exist_ok=True,
)

backup_path = (
    BACKUP_ROOT
    / f"{cid}.before.json"
)

shutil.copy2(
    latest_path,
    backup_path,
)


publish_before = (
    cid
    in publishable_config_ids()
)


started = time.time()


result = run_health_once(
    config_id=job.config_id,
    config_type=job.config_type,
    source=job.source,
)


elapsed = time.time() - started


store = JsonHealthResultStore(
    HEALTH_ROOT
)

store.save(
    result
)


after_hash = sha256(
    latest_path
)

after_mtime = (
    latest_path.stat().st_mtime_ns
)


after_payload = json.loads(
    latest_path.read_text(
        encoding="utf-8"
    )
)


publish_immediate = (
    cid
    in publishable_config_ids()
)


# Allow existing lifecycle/sync components
# a short observation window.
time.sleep(5)


publish_after_wait = (
    cid
    in publishable_config_ids()
)


output = {
    "mode":
        "controlled_canary",

    "canary_count":
        1,

    "selected": {
        "config_id":
            cid,

        "config_type":
            job.config_type,

        "age_seconds":
            selected["age_seconds"],

        "due_by_seconds":
            selected["due_by_seconds"],
    },

    "before": {
        "state":
            before_payload.get(
                "state"
            ),

        "finished_at":
            before_payload.get(
                "finished_at"
            ),

        "xray_started":
            before_payload.get(
                "xray_started"
            ),

        "download_verified":
            before_payload.get(
                "download_verified"
            ),

        "upload_verified":
            before_payload.get(
                "upload_verified"
            ),

        "sha256":
            before_hash,

        "mtime_ns":
            before_mtime,

        "publish_eligible":
            publish_before,
    },

    "retest": {
        "job_id":
            result.job_id,

        "state":
            result.state.value,

        "healthy":
            result.healthy,

        "started_at":
            result.started_at,

        "finished_at":
            result.finished_at,

        "xray_started":
            result.xray_started,

        "download_verified":
            result.download_verified,

        "upload_verified":
            result.upload_verified,

        "error_code":
            result.error_code,

        "error_message":
            result.error_message,

        "elapsed_seconds":
            round(
                elapsed,
                3,
            ),
    },

    "after": {
        "state":
            after_payload.get(
                "state"
            ),

        "finished_at":
            after_payload.get(
                "finished_at"
            ),

        "sha256":
            after_hash,

        "mtime_ns":
            after_mtime,

        "publish_eligible_immediate":
            publish_immediate,

        "publish_eligible_after_5s":
            publish_after_wait,
    },

    "assertions": {
        "latest_changed":
            before_hash
            != after_hash,

        "mtime_advanced":
            after_mtime
            > before_mtime,

        "stored_state_matches":
            after_payload.get(
                "state"
            )
            == result.state.value,

        "stored_job_matches":
            after_payload.get(
                "job_id"
            )
            == result.job_id,

        "manual_delete":
            False,
    },
}


if not output[
    "assertions"
][
    "latest_changed"
]:
    raise AssertionError(
        "canonical latest did not change"
    )


if not output[
    "assertions"
][
    "stored_state_matches"
]:
    raise AssertionError(
        "stored state mismatch"
    )


if not output[
    "assertions"
][
    "stored_job_matches"
]:
    raise AssertionError(
        "stored job mismatch"
    )


OUTPUT.write_text(
    json.dumps(
        output,
        indent=2,
        ensure_ascii=False,
    )
    + "\n",
    encoding="utf-8",
)


print(
    json.dumps(
        output,
        indent=2,
        ensure_ascii=False,
    )
)
PY

sed -i \
  "s|__BACKUP_DIR__|$BACKUP_DIR|g; s|__RESULT_JSON__|$RESULT_JSON|g" \
  /root/phase3-pass2d-canary.py

echo "CANARY_RUNNER_READY"


################################################
# 5 RUN REAL CANARY
################################################

echo
echo "========== [5/9] REAL CANARY EXECUTION =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
/root/phase3-pass2d-canary.py

echo "CANARY_EXECUTION_FINISHED"


################################################
# 6 VALIDATE RESULT
################################################

echo
echo "========== [6/9] VALIDATE =========="

test -s "$RESULT_JSON" || {
    fail "canary result missing"
    exit 1
}

"$PROJECT/venv/bin/python" \
- "$RESULT_JSON" <<'PY'
import json
import sys

data=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

assert data["mode"] == "controlled_canary"
assert data["canary_count"] == 1

a=data["assertions"]

assert a["latest_changed"] is True
assert a["mtime_advanced"] is True
assert a["stored_state_matches"] is True
assert a["stored_job_matches"] is True
assert a["manual_delete"] is False

print("CANARY_VALID")

print(
    "CONFIG_ID=",
    data["selected"]["config_id"],
)

print(
    "BEFORE_STATE=",
    data["before"]["state"],
)

print(
    "AFTER_STATE=",
    data["after"]["state"],
)

print(
    "HEALTHY=",
    data["retest"]["healthy"],
)

print(
    "ELAPSED=",
    data["retest"]["elapsed_seconds"],
)

print(
    "PUBLISH_BEFORE=",
    data["before"]["publish_eligible"],
)

print(
    "PUBLISH_IMMEDIATE=",
    data["after"]["publish_eligible_immediate"],
)

print(
    "PUBLISH_AFTER_5S=",
    data["after"]["publish_eligible_after_5s"],
)
PY


################################################
# 7 HEALTH STORE VERIFY
################################################

echo
echo "========== [7/9] CANONICAL STORE VERIFY =========="

CID="$(
"$PROJECT/venv/bin/python" \
- "$RESULT_JSON" <<'PY'
import json
import sys

print(
    json.load(
        open(
            sys.argv[1]
        )
    )[
        "selected"
    ][
        "config_id"
    ]
)
PY
)"

LATEST_FILE="$LATEST/$CID.json"

test -f "$LATEST_FILE" || {
    fail "latest result missing after canary"
    exit 1
}

echo "LATEST_FILE=$LATEST_FILE"

stat -c \
'%U:%G %a %s %y %n' \
"$LATEST_FILE"

echo "CANONICAL_STORE_OK"


################################################
# 8 JOURNAL OBSERVATION
################################################

echo
echo "========== [8/9] JOURNAL OBSERVATION =========="

journalctl \
  --since "$START" \
  --no-pager \
  2>/dev/null \
  | grep -Ei \
  'config-location|health|lifecycle|publish|xray' \
  | tail -n 120 \
  || true


################################################
# 9 SAFETY
################################################

echo
echo "========== [9/9] SAFETY =========="

echo "CANARY_COUNT=1"
echo "REAL_HEALTH_EXECUTION=YES"
echo "CANONICAL_STORE_SAVE=YES"
echo "MANUAL_DELETE=NO"
echo "SERVICE_RESTART=NO"
echo "BULK_RETEST=NO"

echo
echo "PHASE3_PASS2D_SUCCESS"

RESULT="SUCCESS"
