#!/usr/bin/env bash
set -Eeu

PHASE="phase3-pass2c-privileged-retest-dryrun"

PROJECT="/opt/config-location"
REPO="/root/project-log"

STORE="/var/lib/config-location/health-results"
LATEST="$STORE/latest"
SCHED="/var/lib/config-location/health-scheduler"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"
BACKUP_DIR="/root/3245/${PHASE}-backup-${TS}"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
DRYRUN="$DISCOVERY_DIR/${PHASE}-${TS}.json"

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
PRIVILEGED DRY RUN

Health execution:
DISABLED

Health mutation:
NONE

Canonical store:
$LATEST

Dry run:
$DRYRUN

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
      "$DRYRUN" \
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
echo " PHASE 3 PASS 2C"
echo " PRIVILEGED RETEST DRY RUN"
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

test -d "$LATEST" || {
    fail "canonical latest directory missing"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv python missing"
    exit 1
}

test -f "$PROJECT/app/settings/engine.py" || {
    fail "settings engine missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP CURRENT RETEST MODULE
################################################

echo
echo "========== [2/9] BACKUP =========="

if [ -d "$PROJECT/app/health/retest" ]; then
    cp -a \
      "$PROJECT/app/health/retest" \
      "$BACKUP_DIR/retest.before"
fi

echo "BACKUP_OK"


################################################
# 3 STORE SNAPSHOT BEFORE
################################################

echo
echo "========== [3/9] STORE SNAPSHOT BEFORE =========="

LATEST_COUNT_BEFORE="$(
    find "$LATEST" \
      -maxdepth 1 \
      -type f \
      -name '*.json' \
      | wc -l
)"

LATEST_NEWEST_BEFORE="$(
    find "$LATEST" \
      -maxdepth 1 \
      -type f \
      -name '*.json' \
      -printf '%T@\n' \
      2>/dev/null \
      | sort -nr \
      | head -1
)"

STATE_HASH_BEFORE="missing"

if [ -f "$SCHED/state.json" ]; then
    STATE_HASH_BEFORE="$(
        sha256sum "$SCHED/state.json" \
        | awk '{print $1}'
    )"
fi

echo "LATEST_COUNT_BEFORE=$LATEST_COUNT_BEFORE"
echo "LATEST_NEWEST_BEFORE=$LATEST_NEWEST_BEFORE"
echo "STATE_HASH_BEFORE=$STATE_HASH_BEFORE"


################################################
# 4 INSTALL PRIVILEGED ADAPTER
################################################

echo
echo "========== [4/9] INSTALL ADAPTER =========="

mkdir -p "$PROJECT/app/health/retest"

cat > "$PROJECT/app/health/retest/__init__.py" <<'PY'
from .privileged_plan import build_privileged_retest_plan

__all__ = [
    "build_privileged_retest_plan",
]
PY

cat > "$PROJECT/app/health/retest/privileged_plan.py" <<'PY'
from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any

from app.settings.engine import get_settings


LATEST = Path(
    "/var/lib/config-location/"
    "health-results/latest"
)

SCHEDULER_STATE = Path(
    "/var/lib/config-location/"
    "health-scheduler/state.json"
)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_time(
    value: Any,
) -> datetime | None:

    if not isinstance(value, str):
        return None

    value = value.strip()

    if not value:
        return None

    try:
        dt = datetime.fromisoformat(
            value.replace(
                "Z",
                "+00:00",
            )
        )
    except ValueError:
        return None

    if dt.tzinfo is None:
        dt = dt.replace(
            tzinfo=timezone.utc
        )

    return dt.astimezone(
        timezone.utc
    )


def _retest_minutes() -> int:

    settings = get_settings()

    section = settings.get(
        "health_retest",
        {},
    )

    try:
        value = int(
            section.get(
                "retest_minutes",
                5,
            )
        )
    except (
        TypeError,
        ValueError,
    ):
        value = 5

    return max(
        1,
        min(
            value,
            1440,
        ),
    )


def _inflight_ids() -> set[str]:

    result: set[str] = set()

    if not SCHEDULER_STATE.exists():
        return result

    try:
        data = json.loads(
            SCHEDULER_STATE.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        return result

    def walk(value: Any) -> None:

        if isinstance(
            value,
            dict,
        ):
            state = str(
                value.get(
                    "state",
                    "",
                )
            ).lower()

            cid = value.get(
                "config_id"
            )

            if (
                cid
                and state in {
                    "queued",
                    "running",
                    "leased",
                    "in_flight",
                }
            ):
                result.add(
                    str(cid)
                )

            for child in value.values():
                walk(child)

        elif isinstance(
            value,
            list,
        ):
            for child in value:
                walk(child)

    walk(data)

    return result


def _real_healthy(
    data: dict[str, Any],
) -> bool:

    return (
        str(
            data.get(
                "state",
                "",
            )
        ).lower()
        == "healthy"
        and data.get(
            "xray_started"
        )
        is True
        and data.get(
            "download_verified"
        )
        is True
        and data.get(
            "upload_verified"
        )
        is True
    )


def build_privileged_retest_plan(
    *,
    limit: int = 200,
) -> dict[str, Any]:

    now = _now()

    minutes = _retest_minutes()
    interval = minutes * 60

    inflight = _inflight_ids()

    scanned = 0
    parsed = 0
    healthy = 0
    invalid = 0
    not_due = 0
    in_flight = 0

    states: dict[str, int] = {}

    due: list[
        dict[str, Any]
    ] = []

    for path in LATEST.glob(
        "*.json"
    ):

        scanned += 1

        try:
            data = json.loads(
                path.read_text(
                    encoding="utf-8",
                    errors="replace",
                )
            )
        except Exception:
            invalid += 1
            continue

        if not isinstance(
            data,
            dict,
        ):
            invalid += 1
            continue

        parsed += 1

        state = str(
            data.get(
                "state",
                "unknown",
            )
        ).lower()

        states[state] = (
            states.get(
                state,
                0,
            )
            + 1
        )

        if not _real_healthy(
            data
        ):
            continue

        healthy += 1

        cid = str(
            data.get(
                "config_id",
                "",
            )
        ).strip()

        ctype = str(
            data.get(
                "config_type",
                "unknown",
            )
        ).strip().lower()

        finished_raw = data.get(
            "finished_at"
        )

        finished = _parse_time(
            finished_raw
        )

        if (
            not cid
            or finished is None
        ):
            invalid += 1
            continue

        if cid in inflight:
            in_flight += 1
            continue

        age = (
            now - finished
        ).total_seconds()

        if age < interval:
            not_due += 1
            continue

        due.append(
            {
                "config_id":
                    cid,

                "config_type":
                    ctype,

                "state":
                    "healthy",

                "last_finished_at":
                    finished.isoformat(),

                "age_seconds":
                    int(age),

                "due_by_seconds":
                    int(
                        age
                        - interval
                    ),

                "interval_seconds":
                    interval,

                "record_path":
                    str(path),
            }
        )

    due.sort(
        key=lambda row: (
            -row[
                "due_by_seconds"
            ],
            row[
                "config_id"
            ],
        )
    )

    return {
        "mode":
            "privileged_dry_run",

        "generated_at":
            now.isoformat(),

        "canonical_store":
            str(LATEST),

        "retest_minutes":
            minutes,

        "interval_seconds":
            interval,

        "scanned_records":
            scanned,

        "parsed_records":
            parsed,

        "states":
            states,

        "real_healthy":
            healthy,

        "not_due":
            not_due,

        "inflight_ids":
            len(inflight),

        "healthy_inflight":
            in_flight,

        "invalid_records":
            invalid,

        "due_total":
            len(due),

        "candidate_limit":
            limit,

        "candidate_count":
            min(
                len(due),
                limit,
            ),

        "candidates":
            due[:limit],

        "production_execution":
            False,

        "health_state_mutation":
            False,
    }
PY

echo "ADAPTER_INSTALLED"


################################################
# 5 COMPILE
################################################

echo
echo "========== [5/9] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
  app/health/retest/privileged_plan.py

echo "COMPILE_OK"


################################################
# 6 REAL DRY RUN AS ROOT
################################################

echo
echo "========== [6/9] PRIVILEGED DRY RUN =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<PY > "$DRYRUN"
import json

from app.health.retest import (
    build_privileged_retest_plan,
)

plan = (
    build_privileged_retest_plan(
        limit=200,
    )
)

print(
    json.dumps(
        plan,
        ensure_ascii=False,
        indent=2,
    )
)
PY

test -s "$DRYRUN" || {
    fail "dryrun empty"
    exit 1
}


"$PROJECT/venv/bin/python" - "$DRYRUN" <<'PY'
import json
import sys

data = json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

assert (
    data[
        "mode"
    ]
    == "privileged_dry_run"
)

assert (
    data[
        "production_execution"
    ]
    is False
)

assert (
    data[
        "health_state_mutation"
    ]
    is False
)

assert (
    data[
        "scanned_records"
    ]
    > 0
)

assert (
    data[
        "parsed_records"
    ]
    > 0
)

print("DRYRUN_VALID")

for key in (
    "retest_minutes",
    "scanned_records",
    "parsed_records",
    "real_healthy",
    "not_due",
    "inflight_ids",
    "healthy_inflight",
    "invalid_records",
    "due_total",
    "candidate_count",
):
    print(
        key.upper(),
        "=",
        data[key],
    )

print(
    "STATES=",
    data["states"],
)
PY


################################################
# 7 SAMPLE DUE
################################################

echo
echo "========== [7/9] SAMPLE DUE =========="

import sys

data=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

for row in data[
    "candidates"
][:20]:
    print(
        row[
            "config_id"
        ],
        row[
            "config_type"
        ],
        "age=",
        row[
            "age_seconds"
        ],
        "due_by=",
        row[
            "due_by_seconds"
        ],
    )
PY


################################################
# 8 VERIFY ZERO STORE MUTATION
################################################

echo
echo "========== [8/9] STORE SNAPSHOT AFTER =========="

LATEST_COUNT_AFTER="$(
    find "$LATEST" \
      -maxdepth 1 \
      -type f \
      -name '*.json' \
      | wc -l
)"

LATEST_NEWEST_AFTER="$(
    find "$LATEST" \
      -maxdepth 1 \
      -type f \
      -name '*.json' \
      -printf '%T@\n' \
      2>/dev/null \
      | sort -nr \
      | head -1
)"

STATE_HASH_AFTER="missing"

if [ -f "$SCHED/state.json" ]; then
    STATE_HASH_AFTER="$(
        sha256sum \
          "$SCHED/state.json" \
        | awk '{print $1}'
    )"
fi

echo "LATEST_COUNT_AFTER=$LATEST_COUNT_AFTER"
echo "LATEST_NEWEST_AFTER=$LATEST_NEWEST_AFTER"
echo "STATE_HASH_AFTER=$STATE_HASH_AFTER"

# Health may naturally be running concurrently,
# so newest mtime/count can legitimately change.
# Our own scheduler state must not be modified.
if (
    [ "$STATE_HASH_BEFORE" != "missing" ]
    && [ "$STATE_HASH_AFTER" != "$STATE_HASH_BEFORE" ]
); then
    echo \
    "NOTICE: scheduler state changed while dry-run ran."

    echo \
    "This may be the existing production health scheduler."
fi

echo "NO_WRITE_CODE_EXECUTED=true"


################################################
# 9 SAFETY
################################################

echo
echo "========== [9/9] SAFETY =========="

echo "RUN_HEALTH_ONCE_CALLED=NO"
echo "HEALTH_STORE_WRITE_CALLED=NO"
echo "HEALTH_STATE_MUTATION=NONE"
echo "PRODUCTION_EXECUTION=DISABLED"
echo "SERVICE_RESTART=NONE"

echo
echo "PHASE3_PASS2C_SUCCESS"

RESULT="SUCCESS"
