#!/usr/bin/env bash
set -Eeu

PHASE="phase3-pass2b-canonical-health-store-diagnosis"

PROJECT="/opt/config-location"
REPO="/root/project-log"
STORE="/var/lib/config-location/health-results"
LATEST="$STORE/latest"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
DIAG="$DISCOVERY_DIR/${PHASE}-${TS}.txt"

mkdir -p "$RUN_DIR" "$REPORT_DIR" "$DISCOVERY_DIR"

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
READ ONLY

Production mutation:
NONE

Diagnostic:
$DIAG

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

    git add "$LOG" "$REPORT" "$DIAG" >/dev/null 2>&1 || true

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
echo " PHASE 3 PASS 2B"
echo " CANONICAL HEALTH STORE DIAGNOSIS"
echo "================================================"

test -d "$STORE" || {
    fail "canonical health store missing"
    exit 1
}

test -d "$LATEST" || {
    fail "canonical latest directory missing"
    exit 1
}

{
echo "================================================"
echo " CANONICAL HEALTH STORE DIAGNOSIS"
echo "================================================"

echo "TIME=$(date -Is)"
echo "HOST=$(hostname)"

echo
echo "========== [1] STORE PATH =========="

du -sh "$STORE" 2>/dev/null || true

echo "LATEST_FILES=$(find "$LATEST" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)"
echo "HISTORY_FILES=$(find "$STORE/history" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)"

echo
echo "========== [2] DIRECTORY PERMISSIONS =========="

namei -l "$LATEST" || true

stat -c \
'%A %a %U:%G %n' \
/var/lib/config-location \
"$STORE" \
"$LATEST" \
2>/dev/null || true

echo
echo "========== [3] SAMPLE FILE PERMISSIONS =========="

find "$LATEST" \
  -maxdepth 1 \
  -type f \
  -name '*.json' \
  -printf '%M %m %u:%g %s %p\n' \
  2>/dev/null \
  | head -n 10 || true

SAMPLE="$(
  find "$LATEST" \
    -maxdepth 1 \
    -type f \
    -name '*.json' \
    -print \
    2>/dev/null \
    | head -n 1
)"

echo
echo "SAMPLE=$SAMPLE"

echo
echo "========== [4] ROOT READ TEST =========="

if [ -n "$SAMPLE" ]; then
    python3 - "$SAMPLE" <<'PY'
import json
import sys

p=sys.argv[1]

with open(p, encoding="utf-8") as f:
    data=json.load(f)

print("ROOT_READ_OK")
print("TYPE=", type(data).__name__)

if isinstance(data, dict):
    print("TOP_KEYS=", sorted(data.keys()))

    for key in (
        "job_id",
        "config_id",
        "config_type",
        "state",
        "started_at",
        "finished_at",
        "xray_started",
        "download_verified",
        "upload_verified",
        "error_code",
    ):
        if key in data:
            print(f"{key}={data[key]!r}")
PY
fi

echo
echo "========== [5] CONFIGLOC FILE ACCESS =========="

if [ -n "$SAMPLE" ]; then
    sudo -u configloc \
      test -r "$SAMPLE" \
      && echo "CONFIGLOC_FILE_READABLE=YES" \
      || echo "CONFIGLOC_FILE_READABLE=NO"

    sudo -u configloc \
      head -c 1 "$SAMPLE" >/dev/null 2>&1 \
      && echo "CONFIGLOC_OPEN_OK" \
      || echo "CONFIGLOC_OPEN_FAILED"
fi

echo
echo "========== [6] CONFIGLOC DIRECTORY ACCESS =========="

sudo -u configloc \
  find "$LATEST" \
    -maxdepth 1 \
    -type f \
    -name '*.json' \
    -print 2>&1 \
  | head -n 10 || true

echo
echo "========== [7] ROOT PARSE 100 LATEST =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path
import json

root=Path("/var/lib/config-location/health-results/latest")

count=0
parsed=0
healthy=0
unhealthy=0
other={}

for p in root.glob("*.json"):
    count += 1

    if count > 100:
        break

    try:
        data=json.loads(
            p.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        continue

    if not isinstance(data, dict):
        continue

    parsed += 1

    state=str(
        data.get("state","")
    ).lower()

    if state=="healthy":
        healthy += 1
    elif state=="unhealthy":
        unhealthy += 1
    else:
        other[state]=other.get(state,0)+1

print("ROOT_SAMPLE_COUNT=", count)
print("ROOT_PARSED=", parsed)
print("ROOT_HEALTHY=", healthy)
print("ROOT_UNHEALTHY=", unhealthy)
print("ROOT_OTHER=", other)
PY

echo
echo "========== [8] CONFIGLOC PARSE 100 LATEST =========="

cd "$PROJECT"

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path
import json

root=Path("/var/lib/config-location/health-results/latest")

visible=0
parsed=0
healthy=0
errors=0

try:
    paths=list(root.glob("*.json"))[:100]
except Exception as exc:
    print("GLOB_ERROR=", repr(exc))
    paths=[]

print("CONFIGLOC_VISIBLE_PATHS=", len(paths))

for p in paths:
    visible += 1

    try:
        data=json.loads(
            p.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception as exc:
        errors += 1

        if errors <= 5:
            print(
                "READ_ERROR=",
                p,
                repr(exc),
            )

        continue

    if isinstance(data,dict):
        parsed += 1

        if str(data.get("state","")).lower()=="healthy":
            healthy += 1

print("CONFIGLOC_VISIBLE=", visible)
print("CONFIGLOC_PARSED=", parsed)
print("CONFIGLOC_HEALTHY=", healthy)
print("CONFIGLOC_ERRORS=", errors)
PY

echo
echo "========== [9] JSON STORE API SOURCE =========="

nl -ba \
"$PROJECT/app/health/storage/json_store.py" \
| sed -n '1,360p'

echo
echo "========== [10] JSON STORE PUBLIC API =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import ast
import os
from pathlib import Path

p=Path(
    os.environ["PROJECT"]
)/"app/health/storage/json_store.py"

tree=ast.parse(p.read_text())

for node in tree.body:
    if isinstance(node,ast.ClassDef):
        print("CLASS",node.name)

        for child in node.body:
            if isinstance(
                child,
                (
                    ast.FunctionDef,
                    ast.AsyncFunctionDef,
                ),
            ):
                print(
                    f"  {child.lineno}: {child.name}"
                )
PY

echo
echo "========== [11] STORE CONSTRUCTION CALLS =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'JsonHealthStore|health-results|result_root|store\.save|store\.latest|store\.load' \
  "$PROJECT/app/health" \
  2>/dev/null \
  | head -n 500 || true

echo
echo "========== [12] PRODUCTION SCHEDULER PATHS =========="

nl -ba \
"$PROJECT/app/health/core/production_scheduler.py" \
| sed -n '340,680p'

echo
echo "========== [13] CONFIG STORE =========="

stat -c \
'%A %a %U:%G %n' \
/var/lib/config-location/configs \
2>/dev/null || true

echo "CONFIG_FILES=$(
find /var/lib/config-location/configs \
  -maxdepth 1 \
  -type f 2>/dev/null \
  | wc -l
)"

echo
echo "========== [14] PASS2A MODULE CURRENT =========="

nl -ba \
"$PROJECT/app/health/retest/eligibility.py" \
2>/dev/null \
| sed -n '1,420p' || true

echo
echo "========== [15] CONCLUSION MARKERS =========="

echo "CANONICAL_STORE=$STORE"
echo "CANONICAL_LATEST=$LATEST"
echo "READ_ONLY=true"
echo "NO_HEALTH_EXECUTION=true"
echo "NO_STATE_MUTATION=true"
echo "DIAG_COMPLETE"

} > "$DIAG"

test -s "$DIAG" || {
    fail "diagnostic empty"
    exit 1
}

SIZE="$(stat -c '%s' "$DIAG")"

if [ "$SIZE" -gt $((5*1024*1024)) ]; then
    fail "diagnostic exceeded 5MB"
    exit 1
fi

grep -q 'DIAG_COMPLETE' "$DIAG" || {
    fail "diagnostic incomplete"
    exit 1
}

echo "DIAGNOSTIC_VALID"
echo "PHASE3_PASS2B_SUCCESS"

RESULT="SUCCESS"
