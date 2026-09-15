#!/usr/bin/env bash
set -Eeu

PHASE="phase4-pass3b-safety-snapshot-freshness-orphan-reconciliation"

PROJECT="/opt/config-location"
REPO="/root/project-log"

STATE="/var/lib/config-location/health-lifecycle"
CONFIGS="/var/lib/config-location/configs"
HEALTH="/var/lib/config-location/health-results/latest"

POLICY="$STATE/policy-latest.json"
TRACKER="$STATE/consecutive-state.json"
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

Safety regeneration:
CANONICAL

Config deletion:
NONE

Health mutation:
NONE

Policy mutation:
NONE

Tracker mutation:
NONE

Backup:
$BACKUP_DIR

Result:
$RESULT_JSON

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
echo " PHASE 4 PASS 3B"
echo " SAFETY SNAPSHOT FRESHNESS / ORPHAN RECONCILIATION"
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

for P in \
  "$POLICY" \
  "$TRACKER" \
  "$SAFETY"
do
    test -f "$P" || {
        fail "missing $P"
        exit 1
    }
done

test -d "$CONFIGS" || {
    fail "config store missing"
    exit 1
}

test -d "$HEALTH" || {
    fail "health store missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/10] BACKUP =========="

cp -a "$SAFETY" \
  "$BACKUP_DIR/safety-latest.before.json"

cp -a "$POLICY" \
  "$BACKUP_DIR/policy-latest.reference.json"

cp -a "$TRACKER" \
  "$BACKUP_DIR/consecutive-state.reference.json"

echo "BACKUP_OK"


################################################
# 3 HASH BEFORE
################################################

echo
echo "========== [3/10] HASH BEFORE =========="

SAFETY_HASH_BEFORE="$(
    sha256sum "$SAFETY" | awk '{print $1}'
)"

POLICY_HASH_BEFORE="$(
    sha256sum "$POLICY" | awk '{print $1}'
)"

TRACKER_HASH_BEFORE="$(
    sha256sum "$TRACKER" | awk '{print $1}'
)"

echo "SAFETY_HASH_BEFORE=$SAFETY_HASH_BEFORE"
echo "POLICY_HASH_BEFORE=$POLICY_HASH_BEFORE"
echo "TRACKER_HASH_BEFORE=$TRACKER_HASH_BEFORE"


################################################
# 4 AUDIT OLD SNAPSHOT
################################################

echo
echo "========== [4/10] AUDIT OLD SNAPSHOT =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$SAFETY" "$CONFIGS" "$HEALTH" <<'PY'
import json
import sys
from pathlib import Path

safety=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

configs=Path(sys.argv[2])
health=Path(sys.argv[3])

sample=safety.get(
    "future_enforcement_candidate_sample",
    [],
)

print(
    "OLD_FUTURE_CANDIDATES=",
    safety.get(
        "future_enforcement_candidates"
    ),
)

print(
    "OLD_SAMPLE_COUNT=",
    len(sample)
    if isinstance(sample,list)
    else 0,
)

missing_config=0
missing_health=0

if isinstance(sample,list):
    for item in sample:

        if isinstance(item,dict):
            cid=str(
                item.get(
                    "config_id",
                    "",
                )
            )
        else:
            cid=str(item)

        if not cid:
            continue

        if not (
            configs / f"{cid}.json"
        ).exists():
            missing_config += 1

        if not (
            health / f"{cid}.json"
        ).exists():
            missing_health += 1

print(
    "OLD_SAMPLE_MISSING_CONFIG=",
    missing_config,
)

print(
    "OLD_SAMPLE_MISSING_HEALTH=",
    missing_health,
)
PY


################################################
# 5 BUILD CANONICAL IN MEMORY
################################################

echo
echo "========== [5/10] CANONICAL BUILD =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.lifecycle.safety_gates import (
    build_safety_snapshot,
)

snapshot=build_safety_snapshot()

assert isinstance(snapshot,dict)

print(
    "NEW_FUTURE_CANDIDATES=",
    snapshot.get(
        "future_enforcement_candidates"
    ),
)

print(
    "NEW_MIN_STREAK=",
    snapshot.get(
        "candidate_min_consecutive_unhealthy"
    ),
)

sample=snapshot.get(
    "future_enforcement_candidate_sample",
    [],
)

print(
    "NEW_SAMPLE_COUNT=",
    len(sample)
    if isinstance(sample,list)
    else 0,
)

print(
    "CANONICAL_BUILD_OK"
)
PY


################################################
# 6 WRITE THROUGH OFFICIAL API
################################################

echo
echo "========== [6/10] CANONICAL WRITE =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.health.lifecycle.safety_gates import (
    build_safety_snapshot,
    write_snapshot,
)

snapshot=build_safety_snapshot()

write_snapshot(
    snapshot
)

print(
    "CANONICAL_SAFETY_WRITE_OK"
)
PY

test -s "$SAFETY" || {
    fail "new safety snapshot missing"
    exit 1
}


################################################
# 7 RECONCILE NEW SNAPSHOT
################################################

echo
echo "========== [7/10] RECONCILE NEW SNAPSHOT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$SAFETY" "$POLICY" "$TRACKER" \
  "$CONFIGS" "$HEALTH" "$RESULT_JSON" <<'PY'
from __future__ import annotations

import json
import sys

from pathlib import Path
from typing import Any


SAFETY=Path(sys.argv[1])
POLICY=Path(sys.argv[2])
TRACKER=Path(sys.argv[3])
CONFIGS=Path(sys.argv[4])
HEALTH=Path(sys.argv[5])
OUTPUT=Path(sys.argv[6])


def load(path):
    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        return {}


def index_records(value):
    out={}

    def walk(obj):
        if isinstance(obj,dict):

            cid=obj.get(
                "config_id"
            )

            if cid:
                cid=str(cid)

                existing=out.get(cid)

                score=sum(
                    1
                    for key in (
                        "consecutive_unhealthy",
                        "consecutive_healthy",
                        "last_result_state",
                        "policy_state",
                    )
                    if key in obj
                )

                old_score=(
                    existing[0]
                    if existing
                    else -1
                )

                if score > old_score:
                    out[cid]=(
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
        in out.items()
    }


safety=load(SAFETY)
policy=index_records(
    load(POLICY)
)
tracker=index_records(
    load(TRACKER)
)


sample=safety.get(
    "future_enforcement_candidate_sample",
    [],
)

if not isinstance(sample,list):
    sample=[]


try:
    min_streak=int(
        safety.get(
            "candidate_min_consecutive_unhealthy",
            8,
        )
    )
except Exception:
    min_streak=8


rows=[]

counts={
    "sample_count":0,
    "config_exists":0,
    "config_missing":0,
    "health_exists":0,
    "health_missing":0,
    "current_health_unhealthy":0,
    "policy_delete_shadow":0,
    "tracker_streak_pass":0,
    "tracker_healthy_zero":0,
    "fully_live_safe_candidate":0,
}


for item in sample:

    if isinstance(item,dict):
        cid=str(
            item.get(
                "config_id",
                "",
            )
        ).strip()

        snapshot_streak=item.get(
            "consecutive_unhealthy"
        )

    else:
        cid=str(item).strip()
        snapshot_streak=None

    if not cid:
        continue


    counts["sample_count"] += 1


    config_exists=(
        CONFIGS/f"{cid}.json"
    ).exists()

    health_path=(
        HEALTH/f"{cid}.json"
    )

    health_exists=(
        health_path.exists()
    )


    if config_exists:
        counts[
            "config_exists"
        ] += 1
    else:
        counts[
            "config_missing"
        ] += 1


    if health_exists:
        counts[
            "health_exists"
        ] += 1
    else:
        counts[
            "health_missing"
        ] += 1


    health=load(
        health_path
    ) if health_exists else {}


    health_state=str(
        health.get(
            "state",
            "unknown",
        )
    ).lower()


    if health_state=="unhealthy":
        counts[
            "current_health_unhealthy"
        ] += 1


    p=policy.get(
        cid,
        {}
    )

    t=tracker.get(
        cid,
        {}
    )


    policy_state=str(
        p.get(
            "policy_state",
            p.get(
                "state",
                "unknown",
            ),
        )
    ).lower()


    delete_shadow=bool(
        p.get(
            "delete_candidate_shadow",
            False,
        )
        or policy_state
        == "delete_candidate_shadow"
    )


    if delete_shadow:
        counts[
            "policy_delete_shadow"
        ] += 1


    try:
        u=int(
            t.get(
                "consecutive_unhealthy",
                0,
            )
            or 0
        )
    except Exception:
        u=0


    try:
        h=int(
            t.get(
                "consecutive_healthy",
                0,
            )
            or 0
        )
    except Exception:
        h=0


    streak_pass=(
        u >= min_streak
    )

    healthy_zero=(
        h == 0
    )


    if streak_pass:
        counts[
            "tracker_streak_pass"
        ] += 1

    if healthy_zero:
        counts[
            "tracker_healthy_zero"
        ] += 1


    fully_live=(
        config_exists
        and health_exists
        and health_state=="unhealthy"
        and delete_shadow
        and streak_pass
        and healthy_zero
    )


    if fully_live:
        counts[
            "fully_live_safe_candidate"
        ] += 1


    rows.append(
        {
            "config_id":
                cid,

            "snapshot_streak":
                snapshot_streak,

            "current_tracker_unhealthy":
                u,

            "current_tracker_healthy":
                h,

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

            "streak_pass":
                streak_pass,

            "healthy_zero":
                healthy_zero,

            "fully_live_safe_candidate":
                fully_live,
        }
    )


output={
    "mode":
        "canonical_safety_freshness_reconciliation",

    "production_delete":
        False,

    "candidate_min_consecutive_unhealthy":
        min_streak,

    "future_enforcement_candidates":
        safety.get(
            "future_enforcement_candidates",
            0,
        ),

    "counts":
        counts,

    "rows":
        rows,
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
# 8 VERIFY HASHES
################################################

echo
echo "========== [8/10] HASH AFTER =========="

SAFETY_HASH_AFTER="$(
    sha256sum "$SAFETY" | awk '{print $1}'
)"

POLICY_HASH_AFTER="$(
    sha256sum "$POLICY" | awk '{print $1}'
)"

TRACKER_HASH_AFTER="$(
    sha256sum "$TRACKER" | awk '{print $1}'
)"

echo "SAFETY_HASH_AFTER=$SAFETY_HASH_AFTER"
echo "POLICY_HASH_AFTER=$POLICY_HASH_AFTER"
echo "TRACKER_HASH_AFTER=$TRACKER_HASH_AFTER"

[ "$POLICY_HASH_AFTER" = "$POLICY_HASH_BEFORE" ] || {
    fail "policy unexpectedly mutated"
    exit 1
}

[ "$TRACKER_HASH_AFTER" = "$TRACKER_HASH_BEFORE" ] || {
    fail "tracker unexpectedly mutated"
    exit 1
}

echo "POLICY_UNCHANGED=YES"
echo "TRACKER_UNCHANGED=YES"


################################################
# 9 VALIDATE RESULT
################################################

echo
echo "========== [9/10] VALIDATE =========="

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
    "canonical_safety_freshness_reconciliation"
)

assert (
    d["production_delete"]
    is False
)

print("RECONCILIATION_VALID")

print(
    "FUTURE_CANDIDATES=",
    d[
        "future_enforcement_candidates"
    ],
)

for key,value in d[
    "counts"
].items():
    print(
        key.upper(),
        "=",
        value,
    )

print(
    "LIVE_CANDIDATE_SAMPLE="
)

shown=0

for row in d["rows"]:

    if not row[
        "fully_live_safe_candidate"
    ]:
        continue

    print(
        row["config_id"],
        "snapshot=",
        row[
            "snapshot_streak"
        ],
        "tracker=",
        row[
            "current_tracker_unhealthy"
        ],
        "health=",
        row[
            "health_state"
        ],
        "policy=",
        row[
            "policy_state"
        ],
    )

    shown += 1

    if shown >= 10:
        break
PY


################################################
# 10 FINAL SAFETY
################################################

echo
echo "========== [10/10] FINAL =========="

echo "CANONICAL_SAFETY_REGENERATED=YES"
echo "CONFIG_DELETE=NO"
echo "HEALTH_MUTATION=NO"
echo "POLICY_MUTATION=NO"
echo "TRACKER_MUTATION=NO"
echo "SERVICE_RESTART=NO"
echo "PRODUCTION_DELETE=DISABLED"

echo
echo "PHASE4_PASS3B_SUCCESS"

RESULT="SUCCESS"
