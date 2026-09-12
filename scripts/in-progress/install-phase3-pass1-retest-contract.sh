#!/usr/bin/env bash
set -Eeu

PHASE="phase3-pass1-retest-integration-contract"

PROJECT="/opt/config-location"
REPO="/root/project-log"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
CONTRACT="$DISCOVERY_DIR/${PHASE}-${TS}.txt"

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

Contract:
$CONTRACT

Contract size:
$(du -h "$CONTRACT" 2>/dev/null | awk '{print $1}')

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
      "$CONTRACT" \
      >/dev/null 2>&1 || true

    if ! git diff --cached --quiet; then
        git commit \
          -m "Phase execution $PHASE $TS" \
          >/dev/null 2>&1 || true
    fi

    git push origin main >/dev/null 2>&1 || true

    if [ "$RESULT" != "SUCCESS" ]; then
        exit 1
    fi
}

trap finish EXIT


echo "================================================"
echo " PHASE 3 PASS 1"
echo " RETEST INTEGRATION CONTRACT"
echo "================================================"

echo "START=$START"
echo "HOST=$(hostname)"


################################################
# PRECHECK
################################################

FILES=(
"$PROJECT/app/health/core/models.py"
"$PROJECT/app/health/core/engine.py"
"$PROJECT/app/health/core/batch.py"
"$PROJECT/app/health/core/production_scheduler.py"
"$PROJECT/app/health/core/decision.py"
"$PROJECT/app/health/core/state_machine.py"
"$PROJECT/app/health/core/retry.py"
"$PROJECT/app/health/storage/json_store.py"
"$PROJECT/app/publish/filter.py"
"$PROJECT/app/settings/engine.py"
)

for FILE in "${FILES[@]}"; do
    test -f "$FILE" || {
        fail "missing $FILE"
        exit 1
    }
done

echo "PRECHECK_OK"


################################################
# CONTRACT
################################################

{
echo "================================================"
echo " CONFIG LOCATION"
echo " HEALTH RETEST INTEGRATION CONTRACT"
echo "================================================"

echo
echo "TIME=$(date -Is)"
echo "HOST=$(hostname)"


################################################
# 1 MODELS
################################################

echo
echo "========== [1] HEALTH MODELS =========="

nl -ba "$PROJECT/app/health/core/models.py" \
  | sed -n '1,260p'


################################################
# 2 ENGINE
################################################

echo
echo "========== [2] HEALTH ENGINE =========="

nl -ba "$PROJECT/app/health/core/engine.py" \
  | sed -n '1,300p'


################################################
# 3 DECISION
################################################

echo
echo "========== [3] HEALTH DECISION =========="

nl -ba "$PROJECT/app/health/core/decision.py" \
  | sed -n '1,360p'


################################################
# 4 STATE MACHINE
################################################

echo
echo "========== [4] STATE MACHINE =========="

nl -ba "$PROJECT/app/health/core/state_machine.py" \
  | sed -n '1,360p'


################################################
# 5 RETRY
################################################

echo
echo "========== [5] RETRY =========="

nl -ba "$PROJECT/app/health/core/retry.py" \
  | sed -n '1,420p'


################################################
# 6 BATCH
################################################

echo
echo "========== [6] BATCH =========="

nl -ba "$PROJECT/app/health/core/batch.py" \
  | sed -n '1,420p'


################################################
# 7 PRODUCTION SCHEDULER SYMBOLS
################################################

echo
echo "========== [7] PRODUCTION SCHEDULER SYMBOLS =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import ast
import os
from pathlib import Path

path = (
    Path(os.environ["PROJECT"])
    / "app/health/core/production_scheduler.py"
)

tree = ast.parse(
    path.read_text(
        encoding="utf-8",
        errors="replace",
    )
)

for node in tree.body:
    if isinstance(
        node,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
            ast.ClassDef,
        ),
    ):
        print(
            f"{node.lineno:5d} "
            f"{getattr(node, 'end_lineno', node.lineno):5d} "
            f"{type(node).__name__:18s} "
            f"{node.name}"
        )
PY


################################################
# 8 PRODUCTION SCHEDULER IMPORTANT AREAS
################################################

echo
echo "========== [8] PRODUCTION SCHEDULER CORE =========="

nl -ba \
  "$PROJECT/app/health/core/production_scheduler.py" \
  | sed -n '1,760p'


################################################
# 9 STORAGE SYMBOLS
################################################

echo
echo "========== [9] JSON STORE SYMBOLS =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import ast
import os
from pathlib import Path

path = (
    Path(os.environ["PROJECT"])
    / "app/health/storage/json_store.py"
)

tree = ast.parse(
    path.read_text(
        encoding="utf-8",
        errors="replace",
    )
)

for node in ast.walk(tree):
    if isinstance(
        node,
        (
            ast.FunctionDef,
            ast.AsyncFunctionDef,
            ast.ClassDef,
        ),
    ):
        print(
            f"{node.lineno:5d} "
            f"{getattr(node, 'end_lineno', node.lineno):5d} "
            f"{type(node).__name__:18s} "
            f"{node.name}"
        )
PY


################################################
# 10 STORAGE SOURCE
################################################

echo
echo "========== [10] JSON STORE =========="

nl -ba "$PROJECT/app/health/storage/json_store.py" \
  | sed -n '1,520p'


################################################
# 11 SETTINGS CONTRACT
################################################

echo
echo "========== [11] CENTRAL SETTINGS HEALTH CONTRACT =========="

grep -n \
  -E \
  'health_retest|retest_minutes|healthy_window_hours|config_lifetime|lifetime_hours|health\.' \
  "$PROJECT/app/settings/engine.py" \
  | head -n 200 || true

echo
echo "--- CURRENT SETTINGS ---"

cd "$PROJECT"

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json

from app.settings.engine import (
    get_settings,
    get_settings_status,
)

s = get_settings()
st = get_settings_status()

wanted = {}

for key in (
    "health_retest",
    "source_intelligence",
    "config_lifetime",
):
    if key in s:
        wanted[key] = s[key]

print(
    json.dumps(
        wanted,
        ensure_ascii=False,
        indent=2,
    )
)

print(
    "SETTINGS_REVISION=",
    st["revision"],
)

print(
    "SETTINGS_CHECKSUM=",
    st["checksum"],
)
PY


################################################
# 12 HEALTH RESULT FILE SAMPLE
################################################

echo
echo "========== [12] HEALTH RESULT STORAGE SUMMARY =========="

for DIR in \
  "$PROJECT/health-results" \
  /var/lib/config-location/health-results \
  /var/lib/config-location/health \
  /var/lib/config-location/health-scheduler
do
    if [ -e "$DIR" ]; then
        echo
        echo "--- $DIR ---"

        du -sh "$DIR" 2>/dev/null || true

        find "$DIR" \
          -maxdepth 2 \
          -type f \
          -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' \
          2>/dev/null \
          | sort -r \
          | head -n 30 || true
    fi
done


################################################
# 13 SAMPLE RESULT KEYS ONLY
################################################

echo
echo "========== [13] SAMPLE HEALTH RESULT STRUCTURE =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json
from pathlib import Path

roots = [
    Path("/var/lib/config-location"),
    Path("/opt/config-location"),
]

seen = 0

for root in roots:
    if not root.exists():
        continue

    for p in root.rglob("*.json"):
        low = str(p).lower()

        if "health" not in low:
            continue

        try:
            if p.stat().st_size > 2_000_000:
                continue

            data = json.loads(
                p.read_text(
                    encoding="utf-8",
                    errors="replace",
                )
            )
        except Exception:
            continue

        print()
        print("FILE:", p)

        if isinstance(data, dict):
            print(
                "TOP_KEYS:",
                sorted(data.keys()),
            )

            for key in (
                "config_id",
                "state",
                "health_state",
                "timestamp",
                "created_at",
                "updated_at",
                "checked_at",
                "last_health_at",
                "next_check_at",
                "result",
                "reason",
            ):
                if key in data:
                    value = data[key]

                    if isinstance(
                        value,
                        (str, int, float, bool, type(None)),
                    ):
                        print(
                            f"{key}={value!r}"
                        )
                    else:
                        print(
                            f"{key}=<{type(value).__name__}>"
                        )

        elif isinstance(data, list):
            print(
                "LIST_LENGTH:",
                len(data),
            )

            if data and isinstance(data[0], dict):
                print(
                    "FIRST_KEYS:",
                    sorted(data[0].keys()),
                )

        seen += 1

        if seen >= 12:
            raise SystemExit

print("SAMPLES=", seen)
PY


################################################
# 14 PUBLISH FILTER
################################################

echo
echo "========== [14] PUBLISH FILTER =========="

nl -ba "$PROJECT/app/publish/filter.py" \
  | sed -n '1,360p'


################################################
# 15 EXACT HEALTH CALL GRAPH
################################################

echo
echo "========== [15] EXACT CALL GRAPH =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'run_health_once\(|run_health_with_retry\(|apply_health_decision\(|discover_jobs\(|publishable_config_ids\(|build_publish_snapshot\(' \
  "$PROJECT/app" \
  2>/dev/null \
  | head -n 500 || true


################################################
# 16 SYSTEMD HEALTH CONTRACT
################################################

echo
echo "========== [16] HEALTH SYSTEMD =========="

systemctl list-unit-files \
  --no-pager \
  | grep -Ei \
  'config-location.*health|health.*config-location' \
  || true

for UNIT in $(
    systemctl list-unit-files \
      --no-legend \
      | awk '{print $1}' \
      | grep -Ei \
      'config-location.*health|health.*config-location'
); do

    echo
    echo "----- $UNIT -----"

    systemctl cat "$UNIT" \
      2>/dev/null \
      | head -n 250 || true

    echo
    echo "STATE:"

    systemctl status "$UNIT" \
      --no-pager \
      -l \
      2>/dev/null \
      | head -n 80 || true
done


################################################
# 17 INTEGRATION QUESTIONS
################################################

echo
echo "========== [17] CONTRACT QUESTIONS =========="

cat <<'QUESTIONS'
Q1. What exact object represents a health job?
Q2. What fields uniquely identify a config?
Q3. What exact function performs the real health test?
Q4. Does retry wrap run_health_once or vice versa?
Q5. Where is HealthResult persisted?
Q6. Which timestamp represents the last completed health test?
Q7. How are healthy and unhealthy transitions represented?
Q8. How does a config become eligible/ineligible for publish?
Q9. Does the production scheduler already rediscover healthy configs?
Q10. What state/cursor prevents duplicate scheduling?
Q11. Which lock prevents multiple health schedulers?
Q12. What is the safest insertion point for retest eligibility?
Q13. Can retest reuse discover_jobs without changing the probe engine?
Q14. What Central Settings key must control the interval?
Q15. What must happen immediately after a failed retest?
QUESTIONS


################################################
# 18 END
################################################

echo
echo "========== [18] CONTRACT COMPLETE =========="

echo "NO_PRODUCTION_CHANGES=true"
echo "NO_SERVICE_RESTART=true"
echo "NO_HEALTH_STATE_CHANGE=true"
echo "CONTRACT_COMPLETE"

} > "$CONTRACT"


################################################
# VALIDATE
################################################

echo
echo "========== CONTRACT SIZE =========="

du -h "$CONTRACT"
wc -l "$CONTRACT"

SIZE="$(stat -c '%s' "$CONTRACT")"
MAX=$((8 * 1024 * 1024))

if [ "$SIZE" -gt "$MAX" ]; then
    fail "contract exceeded 8MB"
    exit 1
fi

grep -q 'CONTRACT_COMPLETE' "$CONTRACT" || {
    fail "contract incomplete"
    exit 1
}

echo "CONTRACT_VALID"
echo "PHASE3_PASS1_SUCCESS"

RESULT="SUCCESS"
