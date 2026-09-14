#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase1-pass7-panel-runtime-recovery"

PROJECT="/opt/config-location"
LOG_REPO="/root/project-log"
SERVICE="config-location-panel.service"
PORT="4040"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START_ISO="$(date -Is)"

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

Start:
$START_ISO

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
echo " PHASE 1 PASS 7"
echo " PANEL RUNTIME RECOVERY"
echo "================================================"

echo "START=$START_ISO"
echo "HOST=$(hostname)"

echo
echo "========== PRECHECK =========="

test -f "$PROJECT/app/panel/server.py" || {
    fail "server.py missing"
    exit 1
}

test -f "$PROJECT/app/panel/settings_ui.py" || {
    fail "settings_ui.py missing"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv python missing"
    exit 1
}

echo "PRECHECK_OK"

echo
echo "========== BACKUP =========="

cp -a "$PROJECT/app/panel/server.py" \
"$BACKUP_DIR/server.py.before"

cp -a "$PROJECT/app/panel/settings_ui.py" \
"$BACKUP_DIR/settings_ui.py.before"

echo "BACKUP_OK"

echo
echo "========== CURRENT FILE HASHES =========="

sha256sum \
"$PROJECT/app/panel/server.py" \
"$PROJECT/app/panel/settings_ui.py"

echo
echo "========== COMPILE CURRENT FILES =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" -m py_compile \
app/panel/server.py \
app/panel/settings_ui.py

echo "CURRENT_COMPILE_OK"

echo
echo "========== IMPORT CURRENT PANEL =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import app.panel.settings_ui
import app.panel.server
print("CURRENT_IMPORT_OK")
PY

echo
echo "========== SETTINGS ENGINE CHECK =========="

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.settings.engine import get_settings, get_settings_status

s = get_settings()
st = get_settings_status()

assert isinstance(s, dict)
assert st["revision"] >= 1
assert len(st["checksum"]) == 64

print("SETTINGS_ENGINE_OK")
print("REVISION=", st["revision"])
print("CHECKSUM=", st["checksum"])
PY

echo
echo "========== STOP SERVICE =========="

systemctl stop "$SERVICE" || true
sleep 2

echo
echo "========== CHECK PORT CLEARED =========="

if ss -lntp | grep -q ":${PORT}[[:space:]]"; then
    echo "PORT_${PORT}_STILL_LISTENING"
    ss -lntp | grep ":${PORT}" || true
else
    echo "PORT_${PORT}_CLEAR"
fi

echo
echo "========== START SERVICE =========="

systemctl start "$SERVICE"

READY=0

for i in $(seq 1 20); do
    ACTIVE="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"

    LISTENING=0
    if ss -lntp | grep -q ":${PORT}[[:space:]]"; then
        LISTENING=1
    fi

    echo "CHECK_$i ACTIVE=$ACTIVE LISTENING=$LISTENING"

    if [ "$ACTIVE" = "active" ] && [ "$LISTENING" -eq 1 ]; then
        READY=1
        break
    fi

    sleep 1
done

if [ "$READY" -ne 1 ]; then
    echo
    echo "========== CURRENT JOURNAL =========="

    journalctl \
    -u "$SERVICE" \
    --since "$START_ISO" \
    --no-pager || true

    fail "panel did not become ready on port $PORT"
    exit 1
fi

echo "PANEL_RUNTIME_READY"

echo
echo "========== LISTENER =========="

ss -lntp | grep ":${PORT}" || true

echo
echo "========== HTTP ROOT TEST =========="

ROOT_CODE="$(
    curl -sS \
    -o /tmp/config-location-pass7-root.out \
    -w '%{http_code}' \
    http://127.0.0.1:${PORT}/ \
    || true
)"

echo "ROOT_HTTP=$ROOT_CODE"

case "$ROOT_CODE" in
    200|302|303)
        echo "ROOT_REACHABLE"
        ;;
    *)
        cat /tmp/config-location-pass7-root.out 2>/dev/null || true
        fail "root endpoint unhealthy: HTTP $ROOT_CODE"
        exit 1
        ;;
esac

echo
echo "========== HTTP SETTINGS TEST =========="

SETTINGS_CODE="$(
    curl -sS \
    -o /tmp/config-location-pass7-settings.out \
    -w '%{http_code}' \
    http://127.0.0.1:${PORT}/settings \
    || true
)"

echo "SETTINGS_HTTP=$SETTINGS_CODE"

case "$SETTINGS_CODE" in
    200|302|303)
        echo "SETTINGS_REACHABLE"
        ;;
    *)
        echo "========== SETTINGS BODY =========="
        cat /tmp/config-location-pass7-settings.out 2>/dev/null || true

        echo
        echo "========== CURRENT JOURNAL =========="
        journalctl \
        -u "$SERVICE" \
        --since "$START_ISO" \
        --no-pager || true

        fail "settings endpoint unhealthy: HTTP $SETTINGS_CODE"
        exit 1
        ;;
esac

echo
echo "========== CURRENT JOURNAL FATAL CHECK =========="

FATAL="$(
    journalctl \
    -u "$SERVICE" \
    --since "$START_ISO" \
    --no-pager 2>/dev/null \
    | grep -Ei \
    'Traceback|SyntaxError|PermissionError|ModuleNotFoundError|Internal Server Error|Unhandled exception' \
    || true
)"

if [ -n "$FATAL" ]; then
    echo "$FATAL"
    fail "fatal panel error detected in current run"
    exit 1
fi

echo "NO_CURRENT_FATAL_ERRORS"

echo
echo "========== FINAL SERVICE STATUS =========="

systemctl status "$SERVICE" \
--no-pager -l | head -n 40

echo
echo "========== FINAL PORT CHECK =========="

ss -lntp | grep ":${PORT}"

echo
echo "PHASE1_PASS7_SUCCESS"

RESULT="SUCCESS"
