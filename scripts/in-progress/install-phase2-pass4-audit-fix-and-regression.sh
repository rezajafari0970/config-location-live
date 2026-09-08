#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase2-pass4-audit-fix-and-regression"

PROJECT="/opt/config-location"
REPO="/root/project-log"
AUDIT="$PROJECT/app/control/audit.py"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
BACKUP_DIR="/root/3245/${PHASE}-backup-${TS}"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"

mkdir -p "$RUN_DIR" "$REPORT_DIR" "$BACKUP_DIR"

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

    cd "$REPO"

    git add "$LOG" "$REPORT" >/dev/null 2>&1 || true

    if ! git diff --cached --quiet; then
        git commit -m "Phase execution $PHASE $TS" >/dev/null 2>&1 || true
    fi

    git push origin main >/dev/null 2>&1 || true

    if [ "$RESULT" != "SUCCESS" ]; then
        exit 1
    fi
}

trap finish EXIT


echo "================================================"
echo " PHASE 2 PASS 4"
echo " AUDIT FIX + FINAL REGRESSION RERUN"
echo "================================================"

echo "START=$START"
echo "HOST=$(hostname)"


echo
echo "========== [1/9] PRECHECK =========="

test -f "$AUDIT" || {
    fail "audit.py missing"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv python missing"
    exit 1
}

test -f /root/install-phase2-final-regression.sh || {
    fail "phase2 final regression script missing"
    exit 1
}

echo "PRECHECK_OK"


echo
echo "========== [2/9] BACKUP =========="

cp -a "$AUDIT" "$BACKUP_DIR/audit.py.before"

sha256sum "$AUDIT"

echo "BACKUP_OK"


echo
echo "========== [3/9] PATCH AUDIT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path
import ast

path = Path("/opt/config-location/app/control/audit.py")
text = path.read_text(encoding="utf-8")

old = '''LOG_DIR /
        datetime.utcnow()
        .strftime("%Y-%m-%d")
        + ".log"'''

new = '''LOG_DIR / (
        datetime.utcnow()
        .strftime("%Y-%m-%d")
        + ".log"
    )'''

if old in text:
    text = text.replace(old, new)
else:
    # fallback for formatting variants
    text = text.replace(
        'LOG_DIR / datetime.utcnow().strftime("%Y-%m-%d") + ".log"',
        'LOG_DIR / (datetime.utcnow().strftime("%Y-%m-%d") + ".log")'
    )

# verify syntax before write
ast.parse(text)

path.write_text(text, encoding="utf-8")

print("AUDIT_PATCH_OK")
PY


echo
echo "========== [4/9] COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
app/control/audit.py

echo "AUDIT_COMPILE_OK"


echo
echo "========== [5/9] IMPORT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.control.audit import audit
assert callable(audit)
print("AUDIT_IMPORT_OK")
PY


echo
echo "========== [6/9] REAL AUDIT WRITE =========="

BEFORE_COUNT="$(
    find /var/log/config-location/control \
        -maxdepth 1 \
        -type f 2>/dev/null \
    | wc -l
)"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.control.audit import audit

audit(
    "phase2-pass4",
    "success",
    "audit real write test"
)

print("AUDIT_REAL_WRITE_CALL_OK")
PY

AFTER_COUNT="$(
    find /var/log/config-location/control \
        -maxdepth 1 \
        -type f 2>/dev/null \
    | wc -l
)"

echo "AUDIT_FILES_BEFORE=$BEFORE_COUNT"
echo "AUDIT_FILES_AFTER=$AFTER_COUNT"

TODAY_LOG="/var/log/config-location/control/$(date +%Y-%m-%d).log"

test -f "$TODAY_LOG" || {
    fail "audit daily log was not created"
    exit 1
}

tail -n 20 "$TODAY_LOG"

echo "AUDIT_REAL_WRITE_OK"


echo
echo "========== [7/9] HASH =========="

sha256sum "$AUDIT"

echo "AUDIT_HASH_OK"


echo
echo "========== [8/9] RERUN PHASE 2 FINAL REGRESSION =========="

bash /root/install-phase2-final-regression.sh

echo "PHASE2_FINAL_REGRESSION_RERUN_OK"


echo
echo "========== [9/9] FINAL VERIFY =========="

LATEST_REPORT="$(
    ls -1t \
    /root/project-log/reports/phase2-final-regression-*.txt \
    2>/dev/null \
    | head -1
)"

echo "LATEST_REGRESSION_REPORT=$LATEST_REPORT"

test -n "$LATEST_REPORT" || {
    fail "final regression report not found"
    exit 1
}

grep -q '^SUCCESS$' "$LATEST_REPORT" || {
    echo "========== REGRESSION REPORT =========="
    cat "$LATEST_REPORT" || true

    fail "phase2 final regression did not report SUCCESS"
    exit 1
}

echo "PHASE2_FINAL_REGRESSION_CONFIRMED_SUCCESS"

echo
echo "================================================"
echo " PHASE 2 PASS 4: SUCCESS"
echo "================================================"

RESULT="SUCCESS"
