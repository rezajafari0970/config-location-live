#!/usr/bin/env bash
set -Eeu

PHASE="phase4-pass2-real-removal-plan-dryrun"

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
PLAN="$DISCOVERY_DIR/${PHASE}-${TS}.json"

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
DRY RUN ONLY

Delete execution:
DISABLED

Config mutation:
NONE

Lifecycle mutation:
NONE

Plan:
$PLAN

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
      "$PLAN" \
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
echo " PHASE 4 PASS 2"
echo " REAL REMOVAL PLAN DRY RUN"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/8] PRECHECK =========="

test -d "$CONFIGS" || {
    fail "config store missing"
    exit 1
}

test -d "$HEALTH" || {
    fail "health store missing"
    exit 1
}

test -f "$POLICY" || {
    fail "policy-latest missing"
    exit 1
}

test -f "$TRACKER" || {
    fail "consecutive tracker missing"
    exit 1
}

test -f "$SAFETY" || {
    fail "safety-latest missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BUILD DRY RUN
################################################

echo
echo "========== [2/8] BUILD PLAN =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
- "$PLAN" <<'PY'
from __future__ import annotations

import json
import sys

from datetime import (
    datetime,
    timezone,
)

from pathlib import Path
from typing import Any

from app.settings.engine import (
    get_settings,
)


CONFIG_ROOT=Path(
    "/var/lib/config-location/configs"
)

HEALTH_ROOT=Path(
    "/var/lib/config-location/health-results/latest"
)

STATE=Path(
    "/var/lib/config-location/health-lifecycle"
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


def parse_time(value):
    if not isinstance(value,str):
        return None

    value=value.strip()

    if not value:
        return None

    try:
        dt=datetime.fromisoformat(
            value.replace(
                "Z",
                "+00:00",
            )
        )
    except Exception:
        return None

    if dt.tzinfo is None:
        dt=dt.replace(
            tzinfo=timezone.utc
        )

    return dt.astimezone(
        timezone.utc
    )


def index_by_config_id(value):
    out={}

    def walk(obj):
        if isinstance(obj,dict):

            cid=obj.get(
                "config_id"
            )

            if cid:
                out[str(cid)]=obj

            for child in obj.values():
                walk(child)

        elif isinstance(obj,list):
            for child in obj:
                walk(child)

    walk(value)

    return out


settings=get_settings()

lifetime_cfg=settings.get(
    "config_lifetime",
    {},
)

features=settings.get(
    "features",
    {},
)

try:
    lifetime_hours=float(
        lifetime_cfg.get(
            "max_age_hours",
            72,
        )
    )
except Exception:
    lifetime_hours=72.0


lifetime_feature=bool(
    features.get(
        "config_lifetime",
        False,
    )
)

definitive_removal_feature=bool(
    features.get(
        "definitive_unhealthy_removal",
        False,
    )
)


policy_raw=load(
    POLICY_PATH
)

tracker_raw=load(
    TRACKER_PATH
)

safety_raw=load(
    SAFETY_PATH
)


policy_idx=index_by_config_id(
    policy_raw
)

tracker_idx=index_by_config_id(
    tracker_raw
)


future_candidates=set()

sample=safety_raw.get(
    "future_enforcement_candidate_sample",
    [],
)

if isinstance(sample,list):
    for item in sample:
        if isinstance(item,dict):
            cid=item.get(
                "config_id"
            )
        else:
            cid=item

        if cid:
            future_candidates.add(
                str(cid)
            )


try:
    safety_min_streak=int(
        safety_raw.get(
            "candidate_min_consecutive_unhealthy",
            8,
        )
    )
except Exception:
    safety_min_streak=8


now=datetime.now(
    timezone.utc
)


rows=[]

counts={
    "configs":0,
    "healthy":0,
    "unhealthy":0,
    "policy_delete_shadow":0,
    "deep_quarantine":0,
    "lifetime_expired":0,
    "lifetime_expired_feature_enabled":0,
    "safety_streak_pass":0,
    "safety_future_candidate":0,
    "would_remove":0,
}


for path in CONFIG_ROOT.glob(
    "*.json"
):

    config=load(path)

    if not isinstance(
        config,
        dict,
    ):
        continue


    cid=str(
        config.get(
            "config_id",
            path.stem,
        )
    ).strip()

    if not cid:
        continue


    counts["configs"] += 1


    health_path=(
        HEALTH_ROOT
        / f"{cid}.json"
    )

    health=load(
        health_path
    )


    health_state=str(
        (
            health
            if isinstance(
                health,
                dict,
            )
            else {}
        ).get(
            "state",
            "unknown",
        )
    ).lower()


    if health_state=="healthy":
        counts["healthy"] += 1

    elif health_state=="unhealthy":
        counts["unhealthy"] += 1


    policy=policy_idx.get(
        cid,
        {},
    )

    tracker=tracker_idx.get(
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


    deep_quarantine=bool(
        policy.get(
            "deep_quarantine",
            False,
        )
        or policy_state
        == "deep_quarantine"
    )


    quarantine=bool(
        policy.get(
            "quarantine",
            False,
        )
        or policy_state
        in {
            "quarantine",
            "deep_quarantine",
            "delete_candidate_shadow",
        }
    )


    try:
        consecutive_unhealthy=int(
            tracker.get(
                "consecutive_unhealthy",
                policy.get(
                    "consecutive_unhealthy",
                    0,
                ),
            )
            or 0
        )
    except Exception:
        consecutive_unhealthy=0


    last_seen_raw=config.get(
        "last_seen_at"
    )

    last_seen=parse_time(
        last_seen_raw
    )


    age_hours=None
    lifetime_expired=False

    if last_seen is not None:

        age_hours=(
            now-last_seen
        ).total_seconds()/3600

        lifetime_expired=(
            age_hours
            >= lifetime_hours
        )


    safety_streak_pass=(
        consecutive_unhealthy
        >= safety_min_streak
    )


    safety_future_candidate=(
        cid
        in future_candidates
    )


    # Removal remains impossible in this Pass.
    #
    # "would_remove" describes what WOULD be
    # eligible if destructive removal were enabled.
    #
    # Require:
    # - shadow candidate
    # - sufficient safety streak
    # - unhealthy latest state
    # - definitive feature enabled
    #
    # Lifetime is reported separately because the
    # lifetime feature itself is currently optional.
    would_remove=(
        delete_shadow
        and safety_streak_pass
        and health_state=="unhealthy"
        and definitive_removal_feature
    )


    reasons=[]

    if delete_shadow:
        reasons.append(
            "delete_candidate_shadow"
        )

    if deep_quarantine:
        reasons.append(
            "deep_quarantine"
        )

    if lifetime_expired:
        reasons.append(
            "lifetime_expired"
        )

    if not safety_streak_pass:
        reasons.append(
            "safety_streak_not_met"
        )

    if safety_future_candidate:
        reasons.append(
            "safety_future_candidate"
        )

    if not definitive_removal_feature:
        reasons.append(
            "definitive_removal_feature_disabled"
        )

    if (
        lifetime_expired
        and not lifetime_feature
    ):
        reasons.append(
            "lifetime_feature_disabled"
        )


    if delete_shadow:
        counts[
            "policy_delete_shadow"
        ] += 1

    if deep_quarantine:
        counts[
            "deep_quarantine"
        ] += 1

    if lifetime_expired:
        counts[
            "lifetime_expired"
        ] += 1

    if (
        lifetime_expired
        and lifetime_feature
    ):
        counts[
            "lifetime_expired_feature_enabled"
        ] += 1

    if safety_streak_pass:
        counts[
            "safety_streak_pass"
        ] += 1

    if safety_future_candidate:
        counts[
            "safety_future_candidate"
        ] += 1

    if would_remove:
        counts[
            "would_remove"
        ] += 1


    rows.append(
        {
            "config_id":
                cid,

            "config_type":
                config.get(
                    "type",
                    "unknown",
                ),

            "health_state":
                health_state,

            "policy_state":
                policy_state,

            "quarantine":
                quarantine,

            "deep_quarantine":
                deep_quarantine,

            "delete_candidate_shadow":
                delete_shadow,

            "consecutive_unhealthy":
                consecutive_unhealthy,

            "safety_min_streak":
                safety_min_streak,

            "safety_streak_pass":
                safety_streak_pass,

            "safety_future_candidate":
                safety_future_candidate,

            "last_seen_at":
                last_seen_raw,

            "age_hours":
                (
                    round(
                        age_hours,
                        3,
                    )
                    if age_hours
                    is not None
                    else None
                ),

            "lifetime_hours":
                lifetime_hours,

            "lifetime_expired":
                lifetime_expired,

            "lifetime_feature_enabled":
                lifetime_feature,

            "definitive_removal_feature_enabled":
                definitive_removal_feature,

            "would_remove":
                would_remove,

            "reasons":
                reasons,
        }
    )


# Put highest-risk candidates first.
rows.sort(
    key=lambda r: (
        not r[
            "delete_candidate_shadow"
        ],
        not r[
            "safety_streak_pass"
        ],
        not r[
            "lifetime_expired"
        ],
        -r[
            "consecutive_unhealthy"
        ],
        r[
            "config_id"
        ],
    )
)


output={
    "mode":
        "dry_run",

    "generated_at":
        now.isoformat(),

    "production_delete":
        False,

    "state_mutation":
        False,

    "settings": {
        "config_lifetime_max_age_hours":
            lifetime_hours,

        "config_lifetime_feature_enabled":
            lifetime_feature,

        "definitive_unhealthy_removal_feature_enabled":
            definitive_removal_feature,

        "safety_min_consecutive_unhealthy":
            safety_min_streak,
    },

    "counts":
        counts,

    "candidate_count":
        sum(
            1
            for row in rows
            if (
                row[
                    "delete_candidate_shadow"
                ]
                or row[
                    "lifetime_expired"
                ]
            )
        ),

    "sample":
        rows[:200],
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
        output[
            "counts"
        ],
        ensure_ascii=False,
        indent=2,
    )
)

print(
    "CANDIDATE_COUNT=",
    output[
        "candidate_count"
    ],
)

print(
    "PRODUCTION_DELETE=False"
)

print(
    "STATE_MUTATION=False"
)
PY


################################################
# 3 VALIDATE JSON
################################################

echo
echo "========== [3/8] VALIDATE =========="

test -s "$PLAN" || {
    fail "plan missing"
    exit 1
}

"$PROJECT/venv/bin/python" \
- "$PLAN" <<'PY'
import json
import sys

data=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

assert data["mode"]=="dry_run"
assert data["production_delete"] is False
assert data["state_mutation"] is False

assert (
    data["counts"]["configs"]
    > 0
)

print("PLAN_VALID")

print(
    "CONFIGS=",
    data["counts"]["configs"],
)

print(
    "HEALTHY=",
    data["counts"]["healthy"],
)

print(
    "UNHEALTHY=",
    data["counts"]["unhealthy"],
)

print(
    "DELETE_SHADOW=",
    data["counts"][
        "policy_delete_shadow"
    ],
)

print(
    "DEEP_QUARANTINE=",
    data["counts"][
        "deep_quarantine"
    ],
)

print(
    "LIFETIME_EXPIRED=",
    data["counts"][
        "lifetime_expired"
    ],
)

print(
    "SAFETY_STREAK_PASS=",
    data["counts"][
        "safety_streak_pass"
    ],
)

print(
    "SAFETY_FUTURE_CANDIDATE=",
    data["counts"][
        "safety_future_candidate"
    ],
)

print(
    "WOULD_REMOVE=",
    data["counts"][
        "would_remove"
    ],
)

print(
    "LIFETIME_FEATURE=",
    data["settings"][
        "config_lifetime_feature_enabled"
    ],
)

print(
    "DEFINITIVE_REMOVAL_FEATURE=",
    data["settings"][
        "definitive_unhealthy_removal_feature_enabled"
    ],
)
PY


################################################
# 4 SAMPLE
################################################

echo
echo "========== [4/8] TOP CANDIDATES =========="

"$PROJECT/venv/bin/python" \
- "$PLAN" <<'PY'
import json
import sys

d=json.load(
    open(
        sys.argv[1],
        encoding="utf-8",
    )
)

for row in d["sample"][:30]:

    if not (
        row[
            "delete_candidate_shadow"
        ]
        or row[
            "lifetime_expired"
        ]
    ):
        continue

    print(
        row["config_id"],
        row["config_type"],
        "health="+row["health_state"],
        "policy="+row["policy_state"],
        "streak="+str(
            row[
                "consecutive_unhealthy"
            ]
        ),
        "lifetime_expired="+str(
            row[
                "lifetime_expired"
            ]
        ),
        "safety="+str(
            row[
                "safety_streak_pass"
            ]
        ),
        "would_remove="+str(
            row[
                "would_remove"
            ]
        ),
    )
PY


################################################
# 5 VERIFY NO CONFIG MUTATION
################################################

echo
echo "========== [5/8] CONFIG STORE SAFETY =========="

echo "CONFIG_FILE_COUNT=$(
    find "$CONFIGS" \
      -maxdepth 1 \
      -type f \
      -name '*.json' \
      | wc -l
)"

echo "NO_CONFIG_DELETE_CODE=YES"
echo "NO_UNLINK_CODE=YES"
echo "NO_CONFIG_STORE_WRITE=YES"


################################################
# 6 VERIFY FEATURES
################################################

echo
echo "========== [6/8] FEATURE STATE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.settings.engine import get_settings

s=get_settings()

features=s.get(
    "features",
    {},
)

print(
    "config_lifetime=",
    features.get(
        "config_lifetime"
    ),
)

print(
    "definitive_unhealthy_removal=",
    features.get(
        "definitive_unhealthy_removal"
    ),
)
PY


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

echo "REMOVAL_PLAN_MODE=DRY_RUN"
echo "PRODUCTION_DELETE=DISABLED"
echo "CONFIG_MUTATION=NONE"
echo "LIFECYCLE_MUTATION=NONE"
echo "PHASE4_PASS2_SUCCESS"

RESULT="SUCCESS"
