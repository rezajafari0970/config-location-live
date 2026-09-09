#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase2-final-regression"

PROJECT="/opt/config-location"
LOG_REPO="/root/project-log"
SERVICE="config-location-panel.service"
PORT="4040"

CONTROL="$PROJECT/app/control"
POLICY="/etc/config-location/control-policy.json"
TOKEN="/etc/config-location/control-token"

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
    echo
    echo "ERROR: $1"
}

finish() {
    CODE=$?

    if [ "$CODE" -ne 0 ]; then
        RESULT="FAILED"
        ERRORS="${ERRORS}\nscript exit code $CODE"
    fi

    echo
    echo "=============================================="
    echo " FINAL RESULT"
    echo "=============================================="
    echo "RESULT=$RESULT"
    echo "END=$(date -Is)"

    cat > "$REPORT" <<REPORT
CONFIG LOCATION
PHASE 2 FINAL REGRESSION

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
echo " CONFIG LOCATION"
echo " PHASE 2 FINAL REGRESSION"
echo "================================================"

echo
echo "START=$START_ISO"
echo "HOST=$(hostname)"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/13] PRECHECK =========="

test -d "$CONTROL" || {
    fail "control module directory missing"
    exit 1
}

for f in \
    "$CONTROL/executor.py" \
    "$CONTROL/security.py" \
    "$CONTROL/audit.py" \
    "$CONTROL/api.py"
do
    test -f "$f" || {
        fail "missing $f"
        exit 1
    }
done

test -f "$POLICY" || {
    fail "policy missing"
    exit 1
}

test -f "$TOKEN" || {
    fail "control token missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# 2 BACKUP
################################################

echo
echo "========== [2/13] BACKUP =========="

cp -a "$CONTROL" "$BACKUP_DIR/control"

cp -a "$POLICY" \
    "$BACKUP_DIR/control-policy.json"

# do NOT copy token contents into project-log
stat "$TOKEN" > "$BACKUP_DIR/token-stat.txt"

echo "BACKUP_OK"


################################################
# 3 PERMISSIONS
################################################

echo
echo "========== [3/13] PERMISSIONS =========="

stat -c \
    'POLICY=%U:%G %a %n' \
    "$POLICY"

stat -c \
    'TOKEN=%U:%G %a %n' \
    "$TOKEN"

TOKEN_MODE="$(stat -c '%a' "$TOKEN")"

case "$TOKEN_MODE" in
    600|640)
        ;;
    *)
        fail "unsafe token mode: $TOKEN_MODE"
        exit 1
        ;;
esac

echo "PERMISSIONS_OK"


################################################
# 4 POLICY JSON
################################################

echo
echo "========== [4/13] POLICY VALIDATION =========="

"$PROJECT/venv/bin/python" - <<'PY'
import json
from pathlib import Path

p = Path("/etc/config-location/control-policy.json")

data = json.loads(p.read_text())

assert isinstance(data, dict)
assert isinstance(data.get("allowed_services"), list)
assert isinstance(data.get("allowed_actions"), list)

assert "config-location-panel.service" in data["allowed_services"]
assert "status" in data["allowed_actions"]

print("POLICY_JSON_OK")
print("allowed_services =", data["allowed_services"])
print("allowed_actions =", data["allowed_actions"])
PY


################################################
# 5 TOKEN VALIDATION
################################################

echo
echo "========== [5/13] TOKEN VALIDATION =========="

"$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path

p = Path("/etc/config-location/control-token")

token = p.read_text().strip()

assert len(token) >= 32
assert all(c in "0123456789abcdefABCDEF" for c in token)

print("TOKEN_FORMAT_OK")
print("TOKEN_LENGTH=", len(token))
PY


################################################
# 6 COMPILE
################################################

echo
echo "========== [6/13] PYTHON COMPILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
    app/control/executor.py \
    app/control/security.py \
    app/control/audit.py \
    app/control/api.py \
    app/panel/server.py

echo "CONTROL_COMPILE_OK"


################################################
# 7 IMPORT
################################################

echo
echo "========== [7/13] IMPORT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.control.executor import (
    service_status,
    restart_service,
)

from app.control.security import (
    check_action,
    check_token,
)

from app.control.audit import audit
from app.control.api import install_control_routes

assert callable(service_status)
assert callable(restart_service)
assert callable(check_action)
assert callable(check_token)
assert callable(audit)
assert callable(install_control_routes)

print("CONTROL_IMPORT_OK")
PY


################################################
# 8 SECURITY TEST
################################################

echo
echo "========== [8/13] SECURITY =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path

from app.control.security import (
    check_action,
    check_token,
)

token = Path(
    "/etc/config-location/control-token"
).read_text().strip()

assert check_token(token) is True
assert check_token("invalid-token") is False

assert check_action("status") is True
assert check_action("restart") is True
assert check_action("__invalid__") is False

print("CONTROL_SECURITY_OK")
PY


################################################
# 9 EXECUTOR STATUS TEST
################################################

echo
echo "========== [9/13] EXECUTOR STATUS =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import asyncio

from app.control.executor import service_status


async def main():

    result = await service_status(
        "config-location-panel.service"
    )

    print("SERVICE_STATUS_RESULT=", result)

    assert result is not None


asyncio.run(main())

print("EXECUTOR_STATUS_OK")
PY


################################################
# 10 AUDIT
################################################

echo
echo "========== [10/13] AUDIT =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.control.audit import audit

audit(
    "phase2-final-regression",
    "success",
    "regression audit test",
)

print("AUDIT_CALL_OK")
PY

test -d /var/log/config-location/control || {
    fail "audit directory not created"
    exit 1
}

echo "AUDIT_OK"


################################################
# 11 PANEL RESTART
################################################

echo
echo "========== [11/13] PANEL RUNTIME =========="

MARK="$(date -Is)"

systemctl restart "$SERVICE"

READY=0

for i in $(seq 1 20); do

    ACTIVE="$(
        systemctl is-active "$SERVICE" \
        2>/dev/null || true
    )"

    LISTEN=0

    if ss -lntp \
        | grep -q ":${PORT}[[:space:]]"
    then
        LISTEN=1
    fi

    echo \
        "CHECK_$i ACTIVE=$ACTIVE LISTENING=$LISTEN"

    if [ "$ACTIVE" = "active" ] \
       && [ "$LISTEN" -eq 1 ]
    then
        READY=1
        break
    fi

    sleep 1
done

if [ "$READY" -ne 1 ]; then

    journalctl \
        -u "$SERVICE" \
        --since "$MARK" \
        --no-pager || true

    fail "panel did not become ready"
    exit 1
fi

echo "PANEL_READY"


################################################
# 12 HTTP + FATAL
################################################

echo
echo "========== [12/13] HTTP / JOURNAL =========="

ROOT_CODE="$(
    curl -sS \
        -o /tmp/phase2-root.out \
        -w '%{http_code}' \
        http://127.0.0.1:${PORT}/ \
        || true
)"

SETTINGS_CODE="$(
    curl -sS \
        -o /tmp/phase2-settings.out \
        -w '%{http_code}' \
        http://127.0.0.1:${PORT}/settings \
        || true
)"

echo "ROOT_HTTP=$ROOT_CODE"
echo "SETTINGS_HTTP=$SETTINGS_CODE"

case "$ROOT_CODE" in
    200|302|303) ;;
    *)
        fail "root endpoint unhealthy"
        exit 1
        ;;
esac

case "$SETTINGS_CODE" in
    200|302|303) ;;
    *)
        fail "settings endpoint unhealthy"
        exit 1
        ;;
esac

FATAL="$(
    journalctl \
        -u "$SERVICE" \
        --since "$MARK" \
        --no-pager 2>/dev/null \
    | grep -Ei \
        'Traceback|SyntaxError|PermissionError|NameError|ModuleNotFoundError|Internal Server Error|Unhandled exception' \
    || true
)"

if [ -n "$FATAL" ]; then
    echo "$FATAL"
    fail "fresh fatal panel errors detected"
    exit 1
fi

echo "HTTP_JOURNAL_OK"


################################################
# 13 FINAL STATE
################################################

echo
echo "========== [13/13] FINAL STATE =========="

systemctl is-active "$SERVICE"

ss -lntp | grep ":${PORT}"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path

from app.control.security import (
    check_action,
    check_token,
)

token = Path(
    "/etc/config-location/control-token"
).read_text().strip()

assert check_token(token)
assert check_action("status")
assert check_action("restart")

print("FINAL_CONTROL_SECURITY_OK")
PY

echo
echo "=============================================="
echo " PHASE 2 FINAL REGRESSION: PASS"
echo "=============================================="

RESULT="SUCCESS"
