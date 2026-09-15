#!/usr/bin/env bash
set -Eeu

PHASE="phase4-pass1-lifecycle-enforcement-contract"

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
        ERRORS="${ERRORS}\nexit code $CODE"
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
READ ONLY CONTRACT

Production changes:
NONE

Delete:
DISABLED

Quarantine mutation:
DISABLED

Service restart:
NONE

Contract:
$CONTRACT

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

    [ "$RESULT" = "SUCCESS" ] || exit 1
}

trap finish EXIT


echo "================================================"
echo " PHASE 4 PASS 1"
echo " LIFECYCLE / ENFORCEMENT CONTRACT"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/12] PRECHECK =========="

FILES=(
"$PROJECT/app/health/lifecycle/engine.py"
"$PROJECT/app/health/lifecycle/policy.py"
"$PROJECT/app/health/lifecycle/consecutive.py"
"$PROJECT/app/health/lifecycle/enforcement.py"
"$PROJECT/app/health/lifecycle/safety_gates.py"
"$PROJECT/app/health/lifecycle/write_control.py"
"$PROJECT/app/health/lifecycle/sync_daemon.py"
"$PROJECT/app/core/config_store.py"
"$PROJECT/app/integrity/referential_guard.py"
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
# 2 BUILD CONTRACT
################################################

{
echo "================================================"
echo " CONFIG LOCATION"
echo " PHASE 4 PASS 1"
echo " LIFECYCLE / ENFORCEMENT CONTRACT"
echo "================================================"

echo "TIME=$(date -Is)"
echo "HOST=$(hostname)"


################################################
# 3 SYMBOL MAP
################################################

echo
echo "========== [2] SYMBOL MAP =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import ast
import os
from pathlib import Path

files=[
    "app/health/lifecycle/engine.py",
    "app/health/lifecycle/policy.py",
    "app/health/lifecycle/consecutive.py",
    "app/health/lifecycle/enforcement.py",
    "app/health/lifecycle/safety_gates.py",
    "app/health/lifecycle/write_control.py",
    "app/health/lifecycle/sync_daemon.py",
    "app/core/config_store.py",
    "app/integrity/referential_guard.py",
    "app/publish/filter.py",
]

root=Path(os.environ["PROJECT"])

for rel in files:
    path=root/rel
    tree=ast.parse(
        path.read_text(
            encoding="utf-8",
            errors="replace",
        )
    )

    print()
    print("FILE:",rel)

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
                f"{getattr(node,'end_lineno',node.lineno):5d} "
                f"{type(node).__name__:18s} "
                f"{node.name}"
            )
PY


################################################
# 4 ENGINE
################################################

echo
echo "========== [3] LIFECYCLE ENGINE =========="

nl -ba \
"$PROJECT/app/health/lifecycle/engine.py" \
| sed -n '1,620p'


################################################
# 5 POLICY
################################################

echo
echo "========== [4] LIFECYCLE POLICY =========="

nl -ba \
"$PROJECT/app/health/lifecycle/policy.py" \
| sed -n '1,620p'


################################################
# 6 CONSECUTIVE
################################################

echo
echo "========== [5] CONSECUTIVE FAILURE =========="

nl -ba \
"$PROJECT/app/health/lifecycle/consecutive.py" \
| sed -n '1,620p'


################################################
# 7 ENFORCEMENT
################################################

echo
echo "========== [6] ENFORCEMENT =========="

nl -ba \
"$PROJECT/app/health/lifecycle/enforcement.py" \
| sed -n '1,760p'


################################################
# 8 SAFETY / WRITE CONTROL
################################################

echo
echo "========== [7] SAFETY GATES =========="

nl -ba \
"$PROJECT/app/health/lifecycle/safety_gates.py" \
| sed -n '1,720p'

echo
echo "========== [8] WRITE CONTROL =========="

nl -ba \
"$PROJECT/app/health/lifecycle/write_control.py" \
| sed -n '1,620p'


################################################
# 9 SYNC DAEMON
################################################

echo
echo "========== [9] SYNC DAEMON =========="

nl -ba \
"$PROJECT/app/health/lifecycle/sync_daemon.py" \
| sed -n '1,760p'


################################################
# 10 CONFIG STORE DELETE API
################################################

echo
echo "========== [10] CONFIG STORE DELETE APIs =========="

grep -n \
  -E \
  'def .*remove|def .*delete|unlink|rmtree|orphan|source_snapshot' \
  "$PROJECT/app/core/config_store.py" \
  | head -n 260 || true

echo
echo "--- relevant config_store excerpts ---"

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path
import re
import os

p=Path(os.environ["PROJECT"])/"app/core/config_store.py"

lines=p.read_text(
    encoding="utf-8",
    errors="replace",
).splitlines()

targets=[]

for i,line in enumerate(lines,1):
    if re.search(
        r'def .*remove|def .*delete|unlink|rmtree|orphan|source_snapshot',
        line,
        re.I,
    ):
        targets.append(i)

shown=set()

for line in targets[:80]:
    start=max(1,line-10)
    end=min(len(lines),line+35)

    key=(start,end)
    if key in shown:
        continue

    shown.add(key)

    print()
    print(f"--- lines {start}-{end} ---")

    for n in range(start,end+1):
        print(f"{n:5d} {lines[n-1]}")
PY


################################################
# 11 ORPHAN / PUBLISH
################################################

echo
echo "========== [11] REFERENTIAL GUARD =========="

nl -ba \
"$PROJECT/app/integrity/referential_guard.py" \
| sed -n '280,560p'

echo
echo "========== [12] PUBLISH FILTER =========="

nl -ba \
"$PROJECT/app/publish/filter.py" \
| sed -n '1,360p'


################################################
# 12 SETTINGS
################################################

echo
echo "========== [13] CENTRAL SETTINGS CONTRACT =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json

from app.settings.engine import get_settings

s=get_settings()

wanted={}

for key in (
    "config_lifetime",
    "cleanup",
    "removal",
    "health",
    "features",
    "publish",
):
    if key in s:
        wanted[key]=s[key]

print(
    json.dumps(
        wanted,
        ensure_ascii=False,
        indent=2,
    )
)
PY


################################################
# 13 RUNTIME FILES
################################################

echo
echo "========== [14] LIFECYCLE RUNTIME STATE =========="

for DIR in \
  /var/lib/config-location/lifecycle \
  /var/lib/config-location/quarantine \
  /var/lib/config-location/removal
do
    echo
    echo "--- $DIR ---"

    if [ -d "$DIR" ]; then
        du -sh "$DIR" 2>/dev/null || true

        find "$DIR" \
          -maxdepth 2 \
          -type f \
          -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' \
          2>/dev/null \
          | sort -r \
          | head -n 80
    else
        echo "MISSING"
    fi
done


################################################
# 14 CALL GRAPH
################################################

echo
echo "========== [15] EXACT CALL GRAPH =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'decide_lifecycle\(|build_lifecycle_snapshot\(|decide_policy\(|apply_policy|consecutive|enforce|delete_candidate|remove_config|delete_config|sweep_orphans\(|reconcile_one_orphan\(|publishable_config_ids\(' \
  "$PROJECT/app" \
  2>/dev/null \
  | head -n 1600 || true


################################################
# 15 CONTRACT QUESTIONS
################################################

echo
echo "========== [16] CONTRACT QUESTIONS =========="

cat <<'QUESTIONS'
Q1. What is the canonical LifecycleState enum?
Q2. What fields exist in LifecycleDecision?
Q3. What exact health states map to quarantine?
Q4. What exact rule escalates quarantine -> deep_quarantine?
Q5. What exact rule creates DELETE_CANDIDATE_SHADOW?
Q6. Does DELETE_CANDIDATE_SHADOW actually delete anything?
Q7. Which function is the true enforcement entrypoint?
Q8. Does enforcement call ConfigStore delete/remove APIs?
Q9. What safety gates must pass before destructive removal?
Q10. Is destructive removal currently enabled or shadow-only?
Q11. What canonical timestamp determines config lifetime?
Q12. Is config_lifetime.lifetime_hours already used in lifecycle logic?
Q13. What happens when a quarantined config becomes healthy again?
Q14. Does Publish exclude quarantine/deep_quarantine/delete-candidate immediately?
Q15. What state/files must be cleaned after a true config removal?
Q16. Does Referential Guard remove orphan country/health/lifecycle state?
Q17. Is there an existing lock/write-control preventing duplicate destructive writes?
Q18. What exact function should a future removal scheduler call?
Q19. What parts can be enabled without changing lifecycle semantics?
Q20. What is the safest Phase 4 Pass 2 dry-run architecture?
QUESTIONS


echo
echo "READ_ONLY=true"
echo "DELETE_EXECUTION=false"
echo "STATE_MUTATION=false"
echo "SERVICE_RESTART=false"
echo "PHASE4_PASS1_CONTRACT_COMPLETE"

} > "$CONTRACT"


################################################
# VALIDATE
################################################

echo
echo "========== CONTRACT VALIDATION =========="

test -s "$CONTRACT" || {
    fail "contract empty"
    exit 1
}

SIZE="$(stat -c '%s' "$CONTRACT")"

if [ "$SIZE" -gt $((10*1024*1024)) ]; then
    fail "contract exceeded 10MB"
    exit 1
fi

grep -q \
  'PHASE4_PASS1_CONTRACT_COMPLETE' \
  "$CONTRACT" || {
    fail "contract incomplete"
    exit 1
}

du -h "$CONTRACT"
wc -l "$CONTRACT"

echo "CONTRACT_VALID"
echo "PHASE4_PASS1_SUCCESS"

RESULT="SUCCESS"
