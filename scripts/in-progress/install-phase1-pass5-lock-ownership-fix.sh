#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase1-pass5-lock-ownership-fix"

PROJECT="/opt/config-location"
LOG_REPO="/root/project-log"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"

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
echo " PHASE 1 PASS 5"
echo " PERSISTENT SETTINGS LOCK OWNERSHIP FIX"
echo "================================================"

echo
echo "START=$(date -Is)"
echo "HOST=$(hostname)"


################################################
# PRECHECK
################################################

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

echo "PRECHECK_OK"


################################################
# BACKUP CURRENT RUNTIME STATE
################################################

echo
echo "========== BACKUP =========="

if [ -d /run/config-location ]; then
    cp -a \
    /run/config-location \
    "$BACKUP_DIR/run-config-location.before"
fi

if [ -f /etc/tmpfiles.d/config-location.conf ]; then
    cp -a \
    /etc/tmpfiles.d/config-location.conf \
    "$BACKUP_DIR/config-location.conf.before"
fi

echo "BACKUP_OK"


################################################
# SHOW CURRENT OWNERSHIP
################################################

echo
echo "========== CURRENT OWNERSHIP =========="

ls -ld /run/config-location 2>/dev/null || true
ls -l /run/config-location/settings.lock 2>/dev/null || true
stat /run/config-location/settings.lock 2>/dev/null || true


################################################
# FIX DIRECTORY
################################################

echo
echo "========== FIX RUNTIME DIRECTORY =========="

mkdir -p /run/config-location

chown configloc:configloc /run/config-location
chmod 0750 /run/config-location

echo "RUNTIME_DIRECTORY_FIXED"


################################################
# REMOVE STALE ROOT-OWNED LOCK
################################################

echo
echo "========== FIX SETTINGS LOCK =========="

if [ -e /run/config-location/settings.lock ]; then

    CURRENT_OWNER="$(
        stat -c '%U:%G' \
        /run/config-location/settings.lock
    )"

    CURRENT_MODE="$(
        stat -c '%a' \
        /run/config-location/settings.lock
    )"

    echo "LOCK_OWNER_BEFORE=$CURRENT_OWNER"
    echo "LOCK_MODE_BEFORE=$CURRENT_MODE"

    rm -f /run/config-location/settings.lock
fi

echo "STALE_LOCK_REMOVED"


################################################
# TMPFILES PERSISTENCE
################################################

echo
echo "========== TMPFILES =========="

cat > /etc/tmpfiles.d/config-location.conf <<'TMP'
d /run/config-location 0750 configloc configloc -
TMP

systemd-tmpfiles \
--create \
/etc/tmpfiles.d/config-location.conf

echo "TMPFILES_OK"


################################################
# CREATE LOCK AS REAL SERVICE USER
################################################

echo
echo "========== CREATE LOCK AS CONFIGLOC =========="

sudo -u configloc bash -c '
set -e

umask 077

touch /run/config-location/settings.lock

echo CONFIGLOC_LOCK_CREATE_OK

stat -c "LOCK_OWNER=%U:%G" \
/run/config-location/settings.lock

stat -c "LOCK_MODE=%a" \
/run/config-location/settings.lock
'

OWNER="$(
    stat -c '%U:%G' \
    /run/config-location/settings.lock
)"

MODE="$(
    stat -c '%a' \
    /run/config-location/settings.lock
)"

if [ "$OWNER" != "configloc:configloc" ]; then
    fail "wrong lock owner: $OWNER"
    exit 1
fi

case "$MODE" in
    600|640|660)
        ;;
    *)
        fail "unexpected lock mode: $MODE"
        exit 1
        ;;
esac

echo "LOCK_OWNERSHIP_OK"


################################################
# DIRECT READ/WRITE TEST
################################################

echo
echo "========== LOCK READ WRITE TEST =========="

sudo -u configloc \
python3 - <<'PY'
import os
import fcntl

path = "/run/config-location/settings.lock"

fd = os.open(
    path,
    os.O_RDWR | os.O_CREAT,
    0o600,
)

fcntl.flock(
    fd,
    fcntl.LOCK_EX
)

print("FLOCK_EX_OK")

fcntl.flock(
    fd,
    fcntl.LOCK_UN
)

print("FLOCK_UNLOCK_OK")

os.close(fd)
PY


################################################
# SETTINGS ENGINE TEST AS CONFIGLOC
################################################

echo
echo "========== SETTINGS ENGINE TEST =========="

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


################################################
# WRITE TEST THROUGH ENGINE
################################################

echo
echo "========== SETTINGS ENGINE WRITE TEST =========="

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.settings.engine import (
    get_settings,
    update_settings,
)

before = get_settings()

current = before[
    "source_intelligence"
][
    "healthy_window_hours"
]

update_settings(
    {
        "source_intelligence": {
            "healthy_window_hours": current
        }
    },
    updated_by="phase1-pass5-selftest",
)

after = get_settings()

assert (
    after[
        "source_intelligence"
    ][
        "healthy_window_hours"
    ]
    == current
)

print("SETTINGS_ENGINE_WRITE_OK")
PY


################################################
# VERIFY LOCK AFTER ENGINE ACCESS
################################################

echo
echo "========== VERIFY LOCK AFTER ENGINE =========="

stat -c \
'LOCK_AFTER=%U:%G %a %n' \
/run/config-location/settings.lock

OWNER_AFTER="$(
    stat -c '%U:%G' \
    /run/config-location/settings.lock
)"

if [ "$OWNER_AFTER" != "configloc:configloc" ]; then
    fail "engine recreated lock with wrong owner"
    exit 1
fi

echo "LOCK_STAYS_CONFIGLOC_OK"


################################################
# PANEL PRE-COMPILE
################################################

echo
echo "========== PANEL PRECHECK =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
"$PROJECT/app/panel/server.py" \
"$PROJECT/app/panel/settings_ui.py"

echo "PANEL_COMPILE_OK"


################################################
# RESTART PANEL
################################################

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
    -n 160 \
    --no-pager || true

    fail "panel inactive"
    exit 1
fi


################################################
# HTTP ROUTES
################################################

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
        -n 200 \
        --no-pager || true

        fail "settings HTTP unhealthy: $SETTINGS_CODE"
        exit 1
        ;;
esac


################################################
# JOURNAL FATAL ERROR CHECK
################################################

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


################################################
# FINAL OWNER CHECK
################################################

echo
echo "========== FINAL LOCK CHECK =========="

stat -c \
'FINAL_LOCK=%U:%G %a %n' \
/run/config-location/settings.lock

echo
echo "PHASE1_PASS5_SUCCESS"

RESULT="SUCCESS"

