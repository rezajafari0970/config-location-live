#!/usr/bin/env bash
set -Eeu

PHASE="phase4-pass3c-stable-canonical-snapshot-verification"

PROJECT="/opt/config-location"
REPO="/root/project-log"

STATE="/var/lib/config-location/health-lifecycle"
CONFIGS="/var/lib/config-location/configs"
HEALTH="/var/lib/config-location/health-results/latest"

SAFETY="$STATE/safety-latest.json"

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
STABLE CANONICAL VERIFICATION

Production delete:
DISABLED

Config mutation:
NONE

Health mutation:
NONE

Policy/tracker live updates:
ALLOWED

Safety snapshot write:
CANONICAL ONLY

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
echo " PHASE 4 PASS 3C"
echo " STABLE CANONICAL SNAPSHOT VERIFICATION"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/8] PRECHECK =========="

[ "$(id -u)" -eq 0 ] || {
    fail "must run as root"
    exit 1
}

test -f "$SAFETY" || {
    fail "safety snapshot missing"
    exit 1
}

test -d "$CONFIGS" || {
    fail "config store missing"
    exit 1
}

test -d "$HEALTH" || {
    fail "health store missing"
    exit 1
}

test -f \
"$PROJECT/app/health/lifecycle/safety_gates.py" || {
    fail "safety_gates.py missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP CURRENT SAFETY
################################################

echo
echo "========== [2/8] BACKUP =========="

cp -a \
  "$SAFETY" \
  "$BACKUP_DIR/safety-latest.before.json"

echo "BACKUP_OK"


################################################
# 3 COMPILE / IMPORT
################################################

echo
echo "========== [3/8] COMPILE + IMPORT =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  app/health/lifecycle/safety_gates.py \
  app/health/lifecycle/policy.py \
  app/health/lifecycle/consecutive.py

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.lifecycle.safety_gates import (
    build_safety_snapshot,
    write_snapshot,
)

assert callable(build_safety_snapshot)
assert callable(write_snapshot)

print("IMPORT_OK")
PY


################################################
# 4 STABLE BUILD / RETRY
################################################

echo
echo "========== [4/8] STABLE BUILD =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$RESULT_JSON" <<'PY'
from __future__ import annotations

import json
import time
import sys

from pathlib import Path
from typing import Any

from app.health.lifecycle.safety_gates import (
    build_safety_snapshot,
    write_snapshot,
)


OUTPUT=Path(sys.argv[1])

CONFIG_ROOT=Path(
    "/var/lib/config-location/configs"
)

HEALTH_ROOT=Path(
    "/var/lib/config-location/health-results/latest"
)


def candidate_map(
    snapshot: dict[str, Any],
) -> dict[str, int]:

    sample=snapshot.get(
        "future_enforcement_candidate_sample",
        [],
    )

    out={}

    if not isinstance(sample,list):
        return out

    for item in sample:

        if isinstance(item,dict):
            cid=str(
                item.get(
                    "config_id",
                    "",
                )
            ).strip()

            try:
                streak=int(
                    item.get(
                        "consecutive_unhealthy",
                        0,
                    )
                    or 0
                )
            except Exception:
                streak=0

        else:
            cid=str(item).strip()
            streak=0

        if cid:
            out[cid]=streak

    return out


def live_check(
    candidates: dict[str,int],
) -> dict[str, Any]:

    rows=[]

    live=0
    missing_config=0
    missing_health=0
    unhealthy=0

    for cid,streak in candidates.items():

        config_exists=(
            CONFIG_ROOT
            / f"{cid}.json"
        ).exists()

        health_path=(
            HEALTH_ROOT
            / f"{cid}.json"
        )

        health_exists=(
            health_path.exists()
        )

        health_state="unknown"

        if health_exists:
            try:
                health=json.loads(
                    health_path.read_text(
                        encoding="utf-8",
                    )
                )

                health_state=str(
                    health.get(
                        "state",
                        "unknown",
                    )
                ).lower()

            except Exception:
                health_state="unknown"

        if not config_exists:
            missing_config += 1

        if not health_exists:
            missing_health += 1

        if health_state=="unhealthy":
            unhealthy += 1

        if (
            config_exists
            and health_exists
            and health_state=="unhealthy"
        ):
            live += 1

        rows.append(
            {
                "config_id":
                    cid,

                "snapshot_streak":
                    streak,

                "config_exists":
                    config_exists,

                "health_exists":
                    health_exists,

                "health_state":
                    health_state,
            }
        )

    return {
        "live":
            live,

        "missing_config":
            missing_config,

        "missing_health":
            missing_health,

        "unhealthy":
            unhealthy,

        "rows":
            rows,
    }


stable=False
attempts=[]

chosen=None

for attempt in range(1,11):

    first=build_safety_snapshot()

    time.sleep(0.25)

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

    first_map=candidate_map(first)
    second_map=candidate_map(second)

    same=(
        first_count==second_count
        and first_map==second_map
    )

    attempts.append(
        {
            "attempt":
                attempt,

            "first_count":
                first_count,

            "second_count":
                second_count,

            "first_sample_count":
                len(first_map),

            "second_sample_count":
                len(second_map),

            "semantic_match":
                same,
        }
    )

    print(
        "ATTEMPT",
        attempt,
        "FIRST=",
        first_count,
        "SECOND=",
        second_count,
        "MATCH=",
        same,
    )

    if same:
        stable=True
        chosen=second
        break

    time.sleep(1)


if not stable or chosen is None:
    raise RuntimeError(
        "could not obtain stable canonical safety snapshot"
    )


# Write ONLY the stable canonical snapshot.
write_snapshot(
    chosen
)


# Rebuild once more after canonical write.
time.sleep(0.25)

verify=build_safety_snapshot()

chosen_count=int(
    chosen.get(
        "future_enforcement_candidates",
        0,
    )
    or 0
)

verify_count=int(
    verify.get(
        "future_enforcement_candidates",
        0,
    )
    or 0
)

chosen_map=candidate_map(
    chosen
)

verify_map=candidate_map(
    verify
)


post_write_match=(
    chosen_count==verify_count
    and chosen_map==verify_map
)


live=live_check(
    verify_map
)


output={
    "mode":
        "stable_canonical_snapshot_verification",

    "production_delete":
        False,

    "stable_snapshot_obtained":
        stable,

    "attempts":
        attempts,

    "canonical_candidate_count":
        verify_count,

    "canonical_sample_count":
        len(verify_map),

    "post_write_semantic_match":
        post_write_match,

    "live_candidate_validation":
        live,

    "candidate_min_consecutive_unhealthy":
        verify.get(
            "candidate_min_consecutive_unhealthy"
        ),

    "hard_safety_boundary":
        verify.get(
            "hard_safety_boundary"
        ),
}


OUTPUT.write_text(
    json.dumps(
        output,
        ensure_ascii=False,
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)


print(
    json.dumps(
        output,
        ensure_ascii=False,
        indent=2,
    )
)
PY


################################################
# 5 VALIDATE
################################################

echo
echo "========== [5/8] VALIDATE =========="

test -s "$RESULT_JSON" || {
    fail "result missing"
    exit 1
}

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
    d["mode"]
    ==
    "stable_canonical_snapshot_verification"
)

assert (
    d["production_delete"]
    is False
)

assert (
    d["stable_snapshot_obtained"]
    is True
)

assert (
    d["post_write_semantic_match"]
    is True
)

print("STABLE_CANONICAL_SNAPSHOT_VALID")

print(
    "CANONICAL_CANDIDATES=",
    d["canonical_candidate_count"],
)

print(
    "SAMPLE_COUNT=",
    d["canonical_sample_count"],
)

print(
    "LIVE=",
    d[
        "live_candidate_validation"
    ][
        "live"
    ],
)

print(
    "MISSING_CONFIG=",
    d[
        "live_candidate_validation"
    ][
        "missing_config"
    ],
)

print(
    "MISSING_HEALTH=",
    d[
        "live_candidate_validation"
    ][
        "missing_health"
    ],
)

print(
    "MIN_STREAK=",
    d[
        "candidate_min_consecutive_unhealthy"
    ],
)

print(
    "HARD_SAFETY_BOUNDARY=",
    d.get(
        "hard_safety_boundary"
    ),
)
PY


################################################
# 6 SAFETY SNAPSHOT EXISTS
################################################

echo
echo "========== [6/8] SNAPSHOT =========="

test -s "$SAFETY" || {
    fail "canonical safety snapshot missing"
    exit 1
}

stat -c \
'%U:%G %a %s %y %n' \
"$SAFETY"

echo "SAFETY_SNAPSHOT_OK"


################################################
# 7 SERVICES
################################################

echo
echo "========== [7/8] SERVICES =========="

systemctl is-active \
  config-location-retest.service \
  2>/dev/null || true

echo "NO_SERVICE_RESTART=YES"


################################################
# 8 FINAL
################################################

echo
echo "========== [8/8] FINAL =========="

echo "POLICY_TRACKER_LIVE_UPDATES=ALLOWED"
echo "RAW_HASH_ASSERTION=REMOVED"

echo "SAFETY_CANONICAL_BUILD=YES"
echo "SAFETY_CANONICAL_WRITE=YES"

echo "CONFIG_DELETE=NO"
echo "PRODUCTION_DELETE=DISABLED"

echo
echo "PHASE4_PASS3C_SUCCESS"

RESULT="SUCCESS"
