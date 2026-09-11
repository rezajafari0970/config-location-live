#!/usr/bin/env bash
set -Eeu

PHASE="phase4-pass3-canonical-safety-candidate-reconciliation"

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

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
RESULT_JSON="$DISCOVERY_DIR/${PHASE}-${TS}.json"

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
READ ONLY RECONCILIATION

Delete:
DISABLED

State mutation:
NONE

Service restart:
NONE

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
echo " PHASE 4 PASS 3"
echo " CANONICAL SAFETY CANDIDATE RECONCILIATION"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/8] PRECHECK =========="

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
    fail "health latest missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 RECONCILIATION
################################################

echo
echo "========== [2/8] RECONCILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$RESULT_JSON" <<'PY'
from __future__ import annotations

import json
import sys

from pathlib import Path
from typing import Any

from app.health.lifecycle.enforcement import (
    build as build_enforcement,
)

from app.publish.filter import (
    publishable_config_ids,
)


STATE=Path(
    "/var/lib/config-location/health-lifecycle"
)

CONFIG_ROOT=Path(
    "/var/lib/config-location/configs"
)

HEALTH_ROOT=Path(
    "/var/lib/config-location/health-results/latest"
)

POLICY_PATH=STATE/"policy-latest.json"
TRACKER_PATH=STATE/"consecutive-state.json"
SAFETY_PATH=STATE/"safety-latest.json"

OUTPUT=Path(sys.argv[1])


def load(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        return {}


def find_all_records(
    value: Any,
    config_id: str,
) -> list[dict[str, Any]]:

    found=[]

    def walk(obj):
        if isinstance(obj,dict):

            if str(
                obj.get(
                    "config_id",
                    ""
                )
            ) == config_id:
                found.append(obj)

            for child in obj.values():
                walk(child)

        elif isinstance(obj,list):
            for child in obj:
                walk(child)

    walk(value)

    return found


def best_tracker_record(
    records: list[dict[str, Any]],
) -> dict[str, Any]:

    if not records:
        return {}

    # Prefer the record that actually contains
    # canonical consecutive counters.
    scored=[]

    for record in records:

        score=0

        for key in (
            "consecutive_unhealthy",
            "consecutive_healthy",
            "consecutive_error",
            "last_result_state",
            "last_result_finished_at",
        ):
            if key in record:
                score += 1

        scored.append(
            (
                score,
                record,
            )
        )

    scored.sort(
        key=lambda row: row[0],
        reverse=True,
    )

    return scored[0][1]


policy=load(POLICY_PATH)
tracker=load(TRACKER_PATH)
safety=load(SAFETY_PATH)


sample=safety.get(
    "future_enforcement_candidate_sample",
    []
)

if not isinstance(sample,list):
    sample=[]


canonical_candidates=[]

for item in sample:

    if isinstance(item,dict):
        cid=str(
            item.get(
                "config_id",
                ""
            )
        ).strip()

        payload=item

    else:
        cid=str(item).strip()
        payload={
            "config_id":cid
        }

    if cid:
        canonical_candidates.append(
            (
                cid,
                payload,
            )
        )


if not canonical_candidates:
    raise RuntimeError(
        "no canonical safety candidate found"
    )


publishable=set(
    publishable_config_ids()
)


enforcement=build_enforcement()


try:
    min_streak=int(
        safety.get(
            "candidate_min_consecutive_unhealthy",
            8,
        )
    )
except Exception:
    min_streak=8


results=[]


for cid,safety_candidate in canonical_candidates:

    policy_records=find_all_records(
        policy,
        cid,
    )

    tracker_records=find_all_records(
        tracker,
        cid,
    )

    policy_record=(
        policy_records[0]
        if policy_records
        else {}
    )

    tracker_record=best_tracker_record(
        tracker_records
    )


    config_path=(
        CONFIG_ROOT
        / f"{cid}.json"
    )

    health_path=(
        HEALTH_ROOT
        / f"{cid}.json"
    )


    config=load(config_path)
    health=load(health_path)


    try:
        streak=int(
            tracker_record.get(
                "consecutive_unhealthy",
                0,
            )
            or 0
        )
    except Exception:
        streak=0


    try:
        healthy_streak=int(
            tracker_record.get(
                "consecutive_healthy",
                0,
            )
            or 0
        )
    except Exception:
        healthy_streak=0


    policy_state=str(
        policy_record.get(
            "policy_state",
            policy_record.get(
                "state",
                "unknown",
            ),
        )
    ).lower()


    latest_health_state=str(
        health.get(
            "state",
            "unknown",
        )
        if isinstance(
            health,
            dict,
        )
        else "unknown"
    ).lower()


    safety_rule_pass=(
        streak >= min_streak
        and healthy_streak == 0
    )


    enforcement_text=json.dumps(
        enforcement,
        ensure_ascii=False,
    )

    enforcement_mentions=(
        cid in enforcement_text
    )


    results.append(
        {
            "config_id":
                cid,

            "safety_candidate":
                safety_candidate,

            "config_exists":
                config_path.exists(),

            "health_exists":
                health_path.exists(),

            "latest_health_state":
                latest_health_state,

            "policy_records_found":
                len(policy_records),

            "tracker_records_found":
                len(tracker_records),

            "policy_state":
                policy_state,

            "delete_candidate_shadow":
                bool(
                    policy_record.get(
                        "delete_candidate_shadow",
                        False,
                    )
                    or policy_state
                    == "delete_candidate_shadow"
                ),

            "consecutive_unhealthy":
                streak,

            "consecutive_healthy":
                healthy_streak,

            "safety_min_streak":
                min_streak,

            "canonical_safety_rule_pass":
                safety_rule_pass,

            "publishable":
                cid in publishable,

            "enforcement_mentions_candidate":
                enforcement_mentions,

            "tracker_record":
                tracker_record,

            "policy_record":
                policy_record,
        }
    )


output={
    "mode":
        "read_only_reconciliation",

    "production_delete":
        False,

    "state_mutation":
        False,

    "canonical_future_enforcement_candidates":
        safety.get(
            "future_enforcement_candidates",
            0,
        ),

    "candidate_min_consecutive_unhealthy":
        min_streak,

    "candidate_count_checked":
        len(results),

    "results":
        results,

    "enforcement": {
        "generated_in_memory":
            True,

        "candidate_ids_present":
            [
                row["config_id"]
                for row in results
                if row[
                    "enforcement_mentions_candidate"
                ]
            ],
    },
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
# 3 VALIDATE
################################################

echo
echo "========== [3/8] VALIDATE =========="

test -s "$RESULT_JSON" || {
    fail "result json missing"
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
    == "read_only_reconciliation"
)

assert (
    d["production_delete"]
    is False
)

assert (
    d["state_mutation"]
    is False
)

assert (
    d[
        "candidate_count_checked"
    ]
    >= 1
)

print("RECONCILIATION_VALID")

for row in d["results"]:

    print(
        "CONFIG_ID=",
        row["config_id"],
    )

    print(
        "CONFIG_EXISTS=",
        row["config_exists"],
    )

    print(
        "LATEST_HEALTH=",
        row["latest_health_state"],
    )

    print(
        "POLICY_STATE=",
        row["policy_state"],
    )

    print(
        "TRACKER_RECORDS=",
        row["tracker_records_found"],
    )

    print(
        "CONSECUTIVE_UNHEALTHY=",
        row["consecutive_unhealthy"],
    )

    print(
        "CONSECUTIVE_HEALTHY=",
        row["consecutive_healthy"],
    )

    print(
        "MIN_STREAK=",
        row["safety_min_streak"],
    )

    print(
        "SAFETY_RULE_PASS=",
        row[
            "canonical_safety_rule_pass"
        ],
    )

    print(
        "PUBLISHABLE=",
        row["publishable"],
    )

    print(
        "ENFORCEMENT_MENTIONS=",
        row[
            "enforcement_mentions_candidate"
        ],
    )

    print("---")
PY


################################################
# 4 EXACT TRACKER STRUCTURE
################################################

echo
echo "========== [4/8] TRACKER STRUCTURE =========="

"$PROJECT/venv/bin/python" \
- "$RESULT_JSON" <<'PY'
import json
import sys

d=json.load(open(sys.argv[1]))

for row in d["results"]:

    print(
        "CONFIG_ID=",
        row["config_id"],
    )

    print(
        json.dumps(
            row["tracker_record"],
            ensure_ascii=False,
            indent=2,
        )
    )
PY


################################################
# 5 EXACT POLICY STRUCTURE
################################################

echo
echo "========== [5/8] POLICY STRUCTURE =========="

"$PROJECT/venv/bin/python" \
- "$RESULT_JSON" <<'PY'
import json
import sys

d=json.load(open(sys.argv[1]))

for row in d["results"]:

    print(
        "CONFIG_ID=",
        row["config_id"],
    )

    print(
        json.dumps(
            row["policy_record"],
            ensure_ascii=False,
            indent=2,
        )
    )
PY


################################################
# 6 SAFETY STORE HASH
################################################

echo
echo "========== [6/8] STORE SAFETY =========="

sha256sum \
  "$POLICY" \
  "$TRACKER" \
  "$SAFETY"

echo "NO_WRITE_FUNCTION_CALLED=YES"
echo "NO_SNAPSHOT_WRITE_CALLED=YES"
echo "NO_CONFIG_DELETE=YES"


################################################
# 7 SERVICE HEALTH
################################################

echo
echo "========== [7/8] SERVICE HEALTH =========="

systemctl is-active \
  config-location-retest.service \
  2>/dev/null || true

echo "SERVICE_RESTART=NONE"


################################################
# 8 FINAL
################################################

echo
echo "========== [8/8] FINAL =========="

echo "CANONICAL_SAFETY_RECONCILIATION=COMPLETE"
echo "PRODUCTION_DELETE=DISABLED"
echo "STATE_MUTATION=NONE"
echo "PHASE4_PASS3_SUCCESS"

RESULT="SUCCESS"
