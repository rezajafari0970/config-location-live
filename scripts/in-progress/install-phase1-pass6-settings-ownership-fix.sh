#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase1-pass6-settings-ownership-fix"

PROJECT="/opt/config-location"
LOG_REPO="/root/project-log"

SETTINGS_ROOT="/var/lib/config-location/settings"
SETTINGS_FILE="$SETTINGS_ROOT/settings.json"
HISTORY_DIR="$SETTINGS_ROOT/history"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"

RUN_DIR="$LOG_REPO/executions/$DATE"
REPORT_DIR="$LOG_REPO/reports"
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

Time:
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

    cd "$LOG_REPO"

    git add "$LOG" "$REPORT" >/dev/null 2>&1 || true

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
echo " PHASE 1 PASS 6"
echo " PERSISTENT SETTINGS OWNERSHIP FIX"
echo "================================================"

echo
echo "START=$(date -Is)"
echo "HOST=$(hostname)"

echo
echo "========== PRECHECK =========="

id configloc

test -x "$PROJECT/venv/bin/python" || {
    fail "project python missing"
    exit 1
}

test -f "$PROJECT/app/settings/engine.py" || {
    fail "settings engine missing"
    exit 1
}

test -f "$SETTINGS_FILE" || {
    fail "settings.json missing"
    exit 1
}

echo "PRECHECK_OK"

echo
echo "========== BACKUP =========="

cp -a "$SETTINGS_ROOT" "$BACKUP_DIR/settings.before"

echo "BACKUP_OK"

echo
echo "========== CURRENT OWNERSHIP =========="

ls -ld \
/var/lib/config-location \
"$SETTINGS_ROOT" \
"$HISTORY_DIR" 2>/dev/null || true

ls -l "$SETTINGS_FILE" 2>/dev/null || true

stat "$SETTINGS_FILE" 2>/dev/null || true

echo
echo "========== FIX SETTINGS ROOT =========="

mkdir -p "$SETTINGS_ROOT" "$HISTORY_DIR"

chown configloc:configloc "$SETTINGS_ROOT"
chown configloc:configloc "$HISTORY_DIR"
chown configloc:configloc "$SETTINGS_FILE"

chmod 0750 "$SETTINGS_ROOT"
chmod 0750 "$HISTORY_DIR"
chmod 0640 "$SETTINGS_FILE"

echo "SETTINGS_ROOT_FIXED"

echo
echo "========== RECURSIVE SAFE OWNERSHIP =========="

find "$HISTORY_DIR" \
    -type d \
    -exec chown configloc:configloc {} \; \
    -exec chmod 0750 {} \;

find "$HISTORY_DIR" \
    -type f \
    -exec chown configloc:configloc {} \; \
    -exec chmod 0640 {} \;

echo "HISTORY_OWNERSHIP_FIXED"

echo
echo "========== DIRECT READ TEST =========="

sudo -u configloc \
cat "$SETTINGS_FILE" \
>/dev/null

echo "SETTINGS_DIRECT_READ_OK"

echo
echo "========== DIRECTORY WRITE TEST =========="

sudo -u configloc bash -c '
set -e

TMP="/var/lib/config-location/settings/.permission-test-$$"

echo test > "$TMP"

test -f "$TMP"

rm -f "$TMP"

echo SETTINGS_DIRECTORY_WRITE_OK
'

echo
echo "========== ATOMIC RENAME TEST =========="

sudo -u configloc \
python3 - <<'PY'
from pathlib import Path
import os
import tempfile

root = Path("/var/lib/config-location/settings")

fd, tmp_name = tempfile.mkstemp(
    prefix=".atomic-test-",
    dir=str(root),
)

with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("ok\n")
    f.flush()
    os.fsync(f.fileno())

tmp = Path(tmp_name)
dst = root / ".atomic-test-final"

os.replace(tmp, dst)

assert dst.read_text(encoding="utf-8") == "ok\n"

dst.unlink()

print("ATOMIC_RENAME_OK")
PY

echo
echo "========== SETTINGS ENGINE READ TEST =========="

cd "$PROJECT"

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.settings.engine import (
    get_settings,
    get_settings_status,
)

settings = get_settings()
status = get_settings_status()

assert isinstance(settings, dict)
assert status["revision"] >= 1
assert len(status["checksum"]) == 64

print("SETTINGS_ENGINE_READ_OK")
print("REVISION=", status["revision"])
print("CHECKSUM=", status["checksum"])
PY

echo
echo "========== SETTINGS ENGINE WRITE/HISTORY TEST =========="

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path

from app.settings.engine import (
    get_settings,
    get_settings_status,
    update_settings,
)

history = Path(
    "/var/lib/config-location/settings/history"
)

before = get_settings()
before_status = get_settings_status()
before_revision = before_status["revision"]

current = before[
    "source_intelligence"
][
    "healthy_window_hours"
]

history_before = {
    p.name
    for p in history.glob("settings-r*.json")
}

update_settings(
    {
        "source_intelligence": {
            "healthy_window_hours": current
        }
    },
    updated_by="phase1-pass6-selftest",
)

after = get_settings()
after_status = get_settings_status()

assert after[
    "source_intelligence"
][
    "healthy_window_hours"
] == current

assert after_status["revision"] == before_revision + 1
assert len(after_status["checksum"]) == 64

history_after = {
    p.name
    for p in history.glob("settings-r*.json")
}

assert len(history_after) >= len(history_before)

print("SETTINGS_ENGINE_WRITE_OK")
print("REVISION_BEFORE=", before_revision)
print("REVISION_AFTER=", after_status["revision"])
print("HISTORY_COUNT=", len(history_after))
PY

echo
echo "========== FINAL SETTINGS OWNERSHIP =========="

stat -c \
'SETTINGS_ROOT=%U:%G %a %n' \
"$SETTINGS_ROOT"

stat -c \
'SETTINGS_FILE=%U:%G %a %n' \
"$SETTINGS_FILE"

stat -c \
'HISTORY_DIR=%U:%G %a %n' \
"$HISTORY_DIR"

echo
echo "========== PANEL COMPILE =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
"$PROJECT/app/panel/server.py" \
"$PROJECT/app/panel/settings_ui.py"

echo "PANEL_COMPILE_OK"

echo
echo "========== PANEL RESTART =========="

systemctl restart \
config-location-panel.service

for i in $(seq 1 15); do
    if systemctl is-active --quiet \
        config-location-panel.service
    then
        echo "PANEL_ACTIVE"
        break
    fi
    sleep 1
done

if ! systemctl is-active --quiet \
    config-location-panel.service
then
    echo
    echo "========== PANEL JOURNAL =========="

    journalctl \
    -u config-location-panel.service \
    -n 180 \
    --no-pager || true

    fail "panel inactive"
    exit 1
fi

echo
echo "========== HTTP TEST =========="

ROOT_CODE="$(
    curl -sS \
    -o /tmp/config-location-root.out \
    -w '%{http_code}' \
    http://127.0.0.1:4040/ \
    || true
)"

SETTINGS_CODE="$(
    curl -sS \
    -o /tmp/config-location-settings.out \
    -w '%{http_code}' \
    http://127.0.0.1:4040/settings \
    || true
)"

echo "ROOT_HTTP=$ROOT_CODE"
echo "SETTINGS_HTTP=$SETTINGS_CODE"

case "$SETTINGS_CODE" in
    200|302|303)
        echo "SETTINGS_ROUTE_REACHABLE"
        ;;
    *)
        echo
        echo "========== SETTINGS RESPONSE =========="

        cat \
        /tmp/config-location-settings.out \
        2>/dev/null || true

        echo
        echo "========== PANEL JOURNAL =========="

        journalctl \
        -u config-location-panel.service \
        -n 220 \
        --no-pager || true

        fail "settings HTTP unhealthy: $SETTINGS_CODE"
        exit 1
        ;;
esac

echo
echo "========== JOURNAL CHECK =========="

FATAL="$(
    journalctl \
    -u config-location-panel.service \
    --since "-2 minutes" \
    --no-pager 2>/dev/null \
    | grep -Ei \
    'PermissionError|Traceback|SyntaxError|ModuleNotFoundError|Internal Server Error' \
    || true
)"

if [ -n "$FATAL" ]; then
    echo "$FATAL"

    fail "recent fatal panel error found"
    exit 1
fi

echo "NO_RECENT_FATAL_PANEL_ERRORS"

echo
echo "PHASE1_PASS6_SUCCESS"

RESULT="SUCCESS"
