#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase1-final-integration-regression"

PROJECT="/opt/config-location"
LOG_REPO="/root/project-log"

SERVICE="config-location-panel.service"
PORT="4040"

SETTINGS_ROOT="/var/lib/config-location/settings"
SETTINGS_FILE="$SETTINGS_ROOT/settings.json"
HISTORY_DIR="$SETTINGS_ROOT/history"
LOCK_FILE="/run/config-location/settings.lock"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START_ISO="$(date -Is)"

RUN_DIR="$LOG_REPO/executions/$DATE"
REPORT_DIR="$LOG_REPO/reports"
BACKUP_DIR="/root/3245/${PHASE}-backup-${TS}"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"

mkdir -p \
    "$RUN_DIR" \
    "$REPORT_DIR" \
    "$BACKUP_DIR"

RESULT="SUCCESS"
ERRORS=""
TEST_VALUE=""
ORIGINAL_VALUE=""
REVISION_START=""
REVISION_TEST=""
REVISION_RESTORE=""

exec 3> >(tee -a "$LOG")
exec 1>&3 2>&1

fail() {
    RESULT="FAILED"
    ERRORS="${ERRORS}\n$1"
    echo
    echo "ERROR: $1"
}

finalize() {
    EXIT_CODE=$?

    if [ "$EXIT_CODE" -ne 0 ]; then
        RESULT="FAILED"
        ERRORS="${ERRORS}\nscript exit code $EXIT_CODE"
    fi

    echo
    echo "================================================"
    echo " FINAL RESULT"
    echo "================================================"
    echo "RESULT=$RESULT"
    echo "END=$(date -Is)"

    cat > "$REPORT" <<REPORT
CONFIG LOCATION
PHASE 1 FINAL INTEGRATION / REGRESSION REPORT

Phase:
$PHASE

Result:
$RESULT

Start:
$START_ISO

End:
$(date -Is)

Original healthy_window_hours:
$ORIGINAL_VALUE

Temporary test value:
$TEST_VALUE

Revision start:
$REVISION_START

Revision after test update:
$REVISION_TEST

Revision after restore:
$REVISION_RESTORE

Backup:
$BACKUP_DIR

Log:
$LOG

Errors:
$ERRORS
REPORT

    # Finish log before Git add.
    exec 1>&-
    exec 2>&-
    exec 3>&-

    sleep 1

    cd "$LOG_REPO" || exit 1

    git add \
        "$LOG" \
        "$REPORT" \
        >/dev/null 2>&1 || true

    if ! git diff --cached --quiet; then
        git commit \
            -m "Phase execution $PHASE $TS" \
            >/dev/null 2>&1 || true
    fi

    git push origin main \
        >/dev/null 2>&1 || true

    if [ "$RESULT" != "SUCCESS" ]; then
        exit 1
    fi
}

trap finalize EXIT


echo "================================================"
echo " CONFIG LOCATION"
echo " PHASE 1 FINAL INTEGRATION / REGRESSION TEST"
echo "================================================"

echo
echo "START=$START_ISO"
echo "HOST=$(hostname)"


################################################
# 1. PRECHECK
################################################

echo
echo "========== [1/16] PRECHECK =========="

id configloc

test -x "$PROJECT/venv/bin/python" || {
    fail "venv python missing"
    exit 1
}

test -f "$PROJECT/app/settings/engine.py" || {
    fail "settings engine missing"
    exit 1
}

test -f "$PROJECT/app/panel/server.py" || {
    fail "panel server missing"
    exit 1
}

test -f "$PROJECT/app/panel/settings_ui.py" || {
    fail "settings UI missing"
    exit 1
}

test -f "$PROJECT/app/panel/page_renderer.py" || {
    fail "page renderer missing"
    exit 1
}

test -f "$SETTINGS_FILE" || {
    fail "settings.json missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2. BACKUP
################################################

echo
echo "========== [2/16] BACKUP =========="

cp -a \
    "$SETTINGS_ROOT" \
    "$BACKUP_DIR/settings.before"

cp -a \
    "$PROJECT/app/settings/engine.py" \
    "$BACKUP_DIR/engine.py"

cp -a \
    "$PROJECT/app/panel/server.py" \
    "$BACKUP_DIR/server.py"

cp -a \
    "$PROJECT/app/panel/settings_ui.py" \
    "$BACKUP_DIR/settings_ui.py"

cp -a \
    "$PROJECT/app/panel/page_renderer.py" \
    "$BACKUP_DIR/page_renderer.py"

echo "BACKUP_OK"


################################################
# 3. OWNERSHIP / LOCK
################################################

echo
echo "========== [3/16] OWNERSHIP + LOCK =========="

stat -c \
    'SETTINGS_DIR=%U:%G %a %n' \
    "$SETTINGS_ROOT"

stat -c \
    'SETTINGS_FILE=%U:%G %a %n' \
    "$SETTINGS_FILE"

stat -c \
    'HISTORY_DIR=%U:%G %a %n' \
    "$HISTORY_DIR"

stat -c \
    'LOCK_FILE=%U:%G %a %n' \
    "$LOCK_FILE"

[ "$(stat -c '%U:%G' "$SETTINGS_FILE")" = "configloc:configloc" ] || {
    fail "settings.json ownership incorrect"
    exit 1
}

[ "$(stat -c '%U:%G' "$LOCK_FILE")" = "configloc:configloc" ] || {
    fail "settings.lock ownership incorrect"
    exit 1
}

echo "OWNERSHIP_LOCK_OK"


################################################
# 4. COMPILE EVERYTHING
################################################

echo
echo "========== [4/16] PYTHON COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
    app/settings/engine.py \
    app/panel/page_renderer.py \
    app/panel/settings_ui.py \
    app/panel/server.py

echo "PYTHON_COMPILE_OK"


################################################
# 5. IMPORT / RENDERER
################################################

echo
echo "========== [5/16] IMPORT + RENDERER =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.panel.page_renderer import page
from app.panel.settings_ui import settings_page
import app.panel.server

assert callable(page)
assert callable(settings_page)

response = page(
    "Final Regression",
    "<div>FINAL_RENDER_TEST</div>",
)

assert response.status == 200
assert b"FINAL_RENDER_TEST" in response.body

print("IMPORT_OK")
print("RENDERER_OK")
PY


################################################
# 6. BASELINE
################################################

echo
echo "========== [6/16] SETTINGS BASELINE =========="

eval "$(
sudo -u configloc \
env PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import shlex

from app.settings.engine import (
    get_settings,
    get_settings_status,
)

s = get_settings()
st = get_settings_status()

value = int(
    s["source_intelligence"]["healthy_window_hours"]
)

revision = int(st["revision"])
checksum = st["checksum"]

print(
    "ORIGINAL_VALUE="
    + shlex.quote(str(value))
)

print(
    "REVISION_START="
    + shlex.quote(str(revision))
)

print(
    "BASE_CHECKSUM="
    + shlex.quote(str(checksum))
)
PY
)"

if [ "$ORIGINAL_VALUE" -eq 13 ]; then
    TEST_VALUE=14
else
    TEST_VALUE=13
fi

echo "ORIGINAL_VALUE=$ORIGINAL_VALUE"
echo "TEST_VALUE=$TEST_VALUE"
echo "REVISION_START=$REVISION_START"
echo "BASE_CHECKSUM=$BASE_CHECKSUM"

HISTORY_START="$(
    find "$HISTORY_DIR" \
        -maxdepth 1 \
        -type f \
        | wc -l
)"

echo "HISTORY_START=$HISTORY_START"


################################################
# 7. TEST UPDATE
################################################

echo
echo "========== [7/16] TEMPORARY SETTINGS UPDATE =========="

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
TEST_VALUE="$TEST_VALUE" \
"$PROJECT/venv/bin/python" - <<'PY'
import os

from app.settings.engine import (
    get_settings,
    get_settings_status,
    update_settings,
)

target = int(os.environ["TEST_VALUE"])

before = get_settings_status()

update_settings(
    {
        "source_intelligence": {
            "healthy_window_hours": target
        }
    },
    updated_by="phase1-final-regression",
)

settings = get_settings()
after = get_settings_status()

assert (
    int(
        settings[
            "source_intelligence"
        ][
            "healthy_window_hours"
        ]
    )
    == target
)

assert (
    int(after["revision"])
    == int(before["revision"]) + 1
)

assert (
    after["checksum"]
    != before["checksum"]
)

print("TEMP_UPDATE_OK")
print("REVISION=", after["revision"])
print("CHECKSUM=", after["checksum"])
PY


################################################
# 8. NEW PROCESS READ
################################################

echo
echo "========== [8/16] NEW PROCESS PERSISTENCE =========="

eval "$(
sudo -u configloc \
env PYTHONPATH="$PROJECT" \
TEST_VALUE="$TEST_VALUE" \
"$PROJECT/venv/bin/python" - <<'PY'
import os
import shlex

from app.settings.engine import (
    get_settings,
    get_settings_status,
)

expected = int(os.environ["TEST_VALUE"])

s = get_settings()
st = get_settings_status()

actual = int(
    s["source_intelligence"]["healthy_window_hours"]
)

assert actual == expected

print(
    "REVISION_TEST="
    + shlex.quote(str(st["revision"]))
)

print(
    "TEST_CHECKSUM="
    + shlex.quote(str(st["checksum"]))
)
PY
)"

echo "NEW_PROCESS_READ_OK"
echo "REVISION_TEST=$REVISION_TEST"
echo "TEST_CHECKSUM=$TEST_CHECKSUM"


################################################
# 9. HISTORY CHECK
################################################

echo
echo "========== [9/16] HISTORY AFTER UPDATE =========="

HISTORY_AFTER_UPDATE="$(
    find "$HISTORY_DIR" \
        -maxdepth 1 \
        -type f \
        | wc -l
)"

echo "HISTORY_AFTER_UPDATE=$HISTORY_AFTER_UPDATE"

if [ "$HISTORY_AFTER_UPDATE" -lt "$HISTORY_START" ]; then
    fail "history count unexpectedly decreased"
    exit 1
fi

find "$HISTORY_DIR" \
    -maxdepth 1 \
    -type f \
    -printf '%TY-%Tm-%Td %TH:%TM:%TS %p\n' \
    | sort \
    | tail -n 10

echo "HISTORY_UPDATE_OK"


################################################
# 10. RESTART WITH TEMP VALUE
################################################

echo
echo "========== [10/16] PANEL RESTART / TEMP VALUE =========="

RESTART_MARK="$(date -Is)"

systemctl restart "$SERVICE"

READY=0

for i in $(seq 1 20); do
    ACTIVE="$(
        systemctl is-active "$SERVICE" \
        2>/dev/null || true
    )"

    LISTENING=0

    if ss -lntp \
        | grep -q ":${PORT}[[:space:]]"
    then
        LISTENING=1
    fi

    echo \
        "CHECK_$i ACTIVE=$ACTIVE LISTENING=$LISTENING"

    if [ "$ACTIVE" = "active" ] \
       && [ "$LISTENING" -eq 1 ]
    then
        READY=1
        break
    fi

    sleep 1
done

if [ "$READY" -ne 1 ]; then
    journalctl \
        -u "$SERVICE" \
        --since "$RESTART_MARK" \
        --no-pager || true

    fail "panel did not recover after restart"
    exit 1
fi

echo "PANEL_RESTART_TEMP_OK"


################################################
# 11. PERSIST AFTER RESTART
################################################

echo
echo "========== [11/16] PERSISTENCE AFTER RESTART =========="

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
TEST_VALUE="$TEST_VALUE" \
"$PROJECT/venv/bin/python" - <<'PY'
import os

from app.settings.engine import get_settings

expected = int(os.environ["TEST_VALUE"])

actual = int(
    get_settings()[
        "source_intelligence"
    ][
        "healthy_window_hours"
    ]
)

assert actual == expected

print("PERSIST_AFTER_RESTART_OK")
print("VALUE=", actual)
PY


################################################
# 12. RESTORE ORIGINAL VALUE
################################################

echo
echo "========== [12/16] RESTORE ORIGINAL SETTING =========="

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
ORIGINAL_VALUE="$ORIGINAL_VALUE" \
"$PROJECT/venv/bin/python" - <<'PY'
import os

from app.settings.engine import (
    get_settings,
    get_settings_status,
    update_settings,
)

original = int(os.environ["ORIGINAL_VALUE"])

before = get_settings_status()

update_settings(
    {
        "source_intelligence": {
            "healthy_window_hours": original
        }
    },
    updated_by="phase1-final-regression-restore",
)

settings = get_settings()
after = get_settings_status()

assert (
    int(
        settings[
            "source_intelligence"
        ][
            "healthy_window_hours"
        ]
    )
    == original
)

assert (
    int(after["revision"])
    == int(before["revision"]) + 1
)

print("ORIGINAL_VALUE_RESTORED")
print("REVISION=", after["revision"])
print("CHECKSUM=", after["checksum"])
PY


################################################
# 13. VERIFY RESTORE IN NEW PROCESS
################################################

echo
echo "========== [13/16] VERIFY RESTORE =========="

eval "$(
sudo -u configloc \
env PYTHONPATH="$PROJECT" \
ORIGINAL_VALUE="$ORIGINAL_VALUE" \
"$PROJECT/venv/bin/python" - <<'PY'
import os
import shlex

from app.settings.engine import (
    get_settings,
    get_settings_status,
)

expected = int(os.environ["ORIGINAL_VALUE"])

s = get_settings()
st = get_settings_status()

actual = int(
    s["source_intelligence"]["healthy_window_hours"]
)

assert actual == expected

print(
    "REVISION_RESTORE="
    + shlex.quote(str(st["revision"]))
)

print(
    "RESTORE_CHECKSUM="
    + shlex.quote(str(st["checksum"]))
)
PY
)"

echo "RESTORE_NEW_PROCESS_OK"
echo "REVISION_RESTORE=$REVISION_RESTORE"
echo "RESTORE_CHECKSUM=$RESTORE_CHECKSUM"

EXPECTED_TEST_REVISION=$((REVISION_START + 1))
EXPECTED_RESTORE_REVISION=$((REVISION_START + 2))

[ "$REVISION_TEST" -eq "$EXPECTED_TEST_REVISION" ] || {
    fail "test revision sequence incorrect"
    exit 1
}

[ "$REVISION_RESTORE" -eq "$EXPECTED_RESTORE_REVISION" ] || {
    fail "restore revision sequence incorrect"
    exit 1
}

echo "REVISION_SEQUENCE_OK"


################################################
# 14. FINAL RESTART / HTTP
################################################

echo
echo "========== [14/16] FINAL PANEL RESTART =========="

FINAL_RESTART_MARK="$(date -Is)"

systemctl restart "$SERVICE"

READY=0

for i in $(seq 1 20); do
    ACTIVE="$(
        systemctl is-active "$SERVICE" \
        2>/dev/null || true
    )"

    LISTENING=0

    if ss -lntp \
        | grep -q ":${PORT}[[:space:]]"
    then
        LISTENING=1
    fi

    echo \
        "FINAL_CHECK_$i ACTIVE=$ACTIVE LISTENING=$LISTENING"

    if [ "$ACTIVE" = "active" ] \
       && [ "$LISTENING" -eq 1 ]
    then
        READY=1
        break
    fi

    sleep 1
done

if [ "$READY" -ne 1 ]; then
    fail "panel unavailable after final restart"
    exit 1
fi

SETTINGS_HTTP="$(
    curl -sS \
        -o /tmp/phase1-final-settings.out \
        -w '%{http_code}' \
        "http://127.0.0.1:${PORT}/settings" \
        || true
)"

echo "SETTINGS_HTTP=$SETTINGS_HTTP"

case "$SETTINGS_HTTP" in
    200|302|303)
        echo "SETTINGS_ROUTE_OK"
        ;;
    *)
        cat \
            /tmp/phase1-final-settings.out \
            2>/dev/null || true

        fail "/settings endpoint unhealthy"
        exit 1
        ;;
esac


################################################
# 15. FINAL HISTORY / JOURNAL
################################################

echo
echo "========== [15/16] FINAL HISTORY + JOURNAL =========="

HISTORY_FINAL="$(
    find "$HISTORY_DIR" \
        -maxdepth 1 \
        -type f \
        | wc -l
)"

echo "HISTORY_START=$HISTORY_START"
echo "HISTORY_FINAL=$HISTORY_FINAL"

if [ "$HISTORY_FINAL" -lt "$HISTORY_AFTER_UPDATE" ]; then
    fail "history decreased after restore"
    exit 1
fi

FATAL="$(
    journalctl \
        -u "$SERVICE" \
        --since "$FINAL_RESTART_MARK" \
        --no-pager 2>/dev/null \
    | grep -Ei \
        'Traceback|SyntaxError|NameError|PermissionError|ModuleNotFoundError|Internal Server Error|Unhandled exception' \
    || true
)"

if [ -n "$FATAL" ]; then
    echo "$FATAL"

    fail "fatal panel error found after final restart"
    exit 1
fi

echo "NO_FINAL_FATAL_ERRORS"


################################################
# 16. FINAL STATE
################################################

echo
echo "========== [16/16] FINAL STATE =========="

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
ORIGINAL_VALUE="$ORIGINAL_VALUE" \
"$PROJECT/venv/bin/python" - <<'PY'
import os

from app.settings.engine import (
    get_settings,
    get_settings_status,
)

expected = int(os.environ["ORIGINAL_VALUE"])

s = get_settings()
st = get_settings_status()

actual = int(
    s["source_intelligence"]["healthy_window_hours"]
)

assert actual == expected
assert len(st["checksum"]) == 64

print("FINAL_SETTINGS_READ_OK")
print("FINAL_VALUE=", actual)
print("FINAL_REVISION=", st["revision"])
print("FINAL_CHECKSUM=", st["checksum"])
PY

echo
echo "SERVICE:"
systemctl is-active "$SERVICE"

echo
echo "PORT:"
ss -lntp | grep ":${PORT}"

echo
echo "LOCK:"
stat -c \
    '%U:%G %a %n' \
    "$LOCK_FILE"

echo
echo "SETTINGS:"
stat -c \
    '%U:%G %a %n' \
    "$SETTINGS_FILE"

echo
echo "================================================"
echo " PHASE 1 FINAL REGRESSION: PASS"
echo "================================================"

RESULT="SUCCESS"
