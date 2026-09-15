#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase1-pass4-settings-ui-recovery"

PROJECT="/opt/config-location"
LOG_REPO="/root/project-log"

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

# keep a dedicated FD for the log so we can close it before git add
exec 3> >(tee -a "$LOG")
exec 1>&3 2>&1

fail() {
    RESULT="FAILED"
    ERRORS="${ERRORS}\n$1"
    echo "ERROR: $1"
}

finish() {
    EXIT_CODE=$?

    if [ "$EXIT_CODE" -ne 0 ]; then
        RESULT="FAILED"
        ERRORS="${ERRORS}\nscript exit code $EXIT_CODE"
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

    # close tee/log stream before git add
    exec 1>&-
    exec 2>&-
    exec 3>&-

    sleep 1

    cd "$LOG_REPO"

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
echo " PHASE 1 PASS 4"
echo " SETTINGS UI RECOVERY"
echo "================================================"

echo "START=$(date -Is)"
echo "HOST=$(hostname)"

SERVER="$PROJECT/app/panel/server.py"
SETTINGS_UI="$PROJECT/app/panel/settings_ui.py"

echo
echo "========== PRECHECK =========="

test -f "$SERVER" || { fail "server.py missing"; exit 1; }

echo "SERVER_OK"

# backup current broken state
cp -a "$SERVER" "$BACKUP_DIR/server.py.current"

if [ -f "$SETTINGS_UI" ]; then
    cp -a "$SETTINGS_UI" "$BACKUP_DIR/settings_ui.py.current"
fi

echo
echo "========== FIND SAFE SETTINGS_UI BACKUP =========="

SAFE_UI=""

while IFS= read -r candidate; do
    if PYTHONPATH="$PROJECT" "$PROJECT/venv/bin/python" -m py_compile "$candidate" >/dev/null 2>&1; then
        SAFE_UI="$candidate"
        break
    fi
done < <(
    find /root/3245 \
        -type f \
        -name 'settings_ui.py' \
        -not -path "*phase1-pass3-settings-ui-fix-backup*" \
        -print 2>/dev/null | sort -r
)

if [ -z "$SAFE_UI" ]; then
    fail "no syntactically valid settings_ui.py backup found"
    exit 1
fi

echo "SAFE_UI=$SAFE_UI"

cp -a "$SAFE_UI" "$SETTINGS_UI"

echo
echo "========== RESTORE COMPILE TEST =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" -m py_compile \
"$SETTINGS_UI" \
"$SERVER"

echo "RESTORE_COMPILE_OK"

echo
echo "========== PATCH LOCK-SAFE SETTINGS PAGE =========="

PYTHONPATH="$PROJECT" "$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path
import ast
import re

path = Path("/opt/config-location/app/panel/settings_ui.py")
text = path.read_text(encoding="utf-8")

# Ensure aiohttp.web is available if this module returns web.Response anywhere
if "from aiohttp import web" not in text and "import aiohttp.web" not in text:
    lines = text.splitlines()
    insert_at = 0
    while insert_at < len(lines) and (
        lines[insert_at].startswith("#!")
        or lines[insert_at].startswith("#")
        or not lines[insert_at].strip()
    ):
        insert_at += 1
    lines.insert(insert_at, "from aiohttp import web")
    text = "\n".join(lines) + "\n"

# Parse now; do not continue if source is not valid.
tree = ast.parse(text)

target = None
for node in tree.body:
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "settings_page":
        target = node
        break

if target is None:
    raise SystemExit("settings_page not found")

# We deliberately do not rewrite function body blindly.
# Only fix the known fragile circular import if present.
text = text.replace(
    "from app.panel.server import page",
    "# page renderer dependency removed from settings_ui"
)

path.write_text(text, encoding="utf-8")
print("SETTINGS_UI_SAFE_PATCH_OK")
PY

echo
echo "========== COMPILE AFTER PATCH =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" -m py_compile \
"$SETTINGS_UI" \
"$SERVER"

echo "COMPILE_OK"

echo
echo "========== IMPORT TEST =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.panel import settings_ui
assert hasattr(settings_ui, "settings_page")
print("SETTINGS_UI_IMPORT_OK")
PY

echo
echo "========== SETTINGS ENGINE TEST AS SERVICE USER =========="

sudo -u configloc env PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.settings.engine import get_settings, get_settings_status

s = get_settings()
st = get_settings_status()

assert isinstance(s, dict)
assert st["revision"] >= 1
assert len(st["checksum"]) == 64

print("SETTINGS_ENGINE_READ_OK")
print("REVISION=", st["revision"])
print("CHECKSUM=", st["checksum"])
PY

echo
echo "========== ROUTE PRESENCE TEST =========="

grep -Rns \
-E 'settings_page|/settings' \
"$PROJECT/app/panel" \
| head -n 50

if ! grep -Rqs '"/settings"' "$PROJECT/app/panel"; then
    fail "/settings route not found"
    exit 1
fi

echo "SETTINGS_ROUTE_PRESENT"

echo
echo "========== SERVER IMPORT TEST =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import app.panel.server
print("SERVER_IMPORT_OK")
PY

echo
echo "========== PRE-RESTART SERVICE CHECK =========="

systemctl is-enabled config-location-panel.service || true

echo
echo "========== RESTART PANEL =========="

systemctl restart config-location-panel.service

for i in $(seq 1 15); do
    if systemctl is-active --quiet config-location-panel.service; then
        echo "PANEL_ACTIVE"
        break
    fi
    sleep 1
done

if ! systemctl is-active --quiet config-location-panel.service; then
    echo "========== PANEL JOURNAL =========="
    journalctl -u config-location-panel.service -n 120 --no-pager || true
    fail "panel failed to become active"
    exit 1
fi

echo
echo "========== LOCAL HTTP TEST =========="

STATUS_ROOT="$(curl -sS -o /tmp/config-location-root.out -w '%{http_code}' \
    http://127.0.0.1:4040/ || true)"

STATUS_SETTINGS="$(curl -sS -o /tmp/config-location-settings.out -w '%{http_code}' \
    http://127.0.0.1:4040/settings || true)"

echo "ROOT_HTTP=$STATUS_ROOT"
echo "SETTINGS_HTTP=$STATUS_SETTINGS"

# unauthenticated request may legitimately redirect to login (302)
case "$STATUS_SETTINGS" in
    200|302|303)
        echo "SETTINGS_HTTP_REACHABLE"
        ;;
    *)
        echo "========== SETTINGS RESPONSE =========="
        cat /tmp/config-location-settings.out 2>/dev/null || true

        echo
        echo "========== PANEL JOURNAL =========="
        journalctl -u config-location-panel.service -n 160 --no-pager || true

        fail "settings endpoint unhealthy: HTTP $STATUS_SETTINGS"
        exit 1
        ;;
esac

echo
echo "========== JOURNAL ERROR CHECK =========="

RECENT_ERRORS="$(
    journalctl -u config-location-panel.service \
        --since "-2 minutes" \
        --no-pager 2>/dev/null \
    | grep -Ei 'Traceback|SyntaxError|PermissionError|Internal Server Error|ModuleNotFoundError' \
    || true
)"

if [ -n "$RECENT_ERRORS" ]; then
    echo "$RECENT_ERRORS"
    fail "recent panel errors detected"
    exit 1
fi

echo "NO_RECENT_FATAL_PANEL_ERRORS"

echo
echo "========== SUCCESS =========="

RESULT="SUCCESS"
