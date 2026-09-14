#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase1-pass9-safe-renderer-recovery"

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

SERVER="$PROJECT/app/panel/server.py"
SETTINGS_UI="$PROJECT/app/panel/settings_ui.py"
RENDERER="$PROJECT/app/panel/page_renderer.py"

echo "================================================"
echo " PHASE 1 PASS 9"
echo " SAFE RENDERER RECOVERY"
echo "================================================"

echo "START=$START_ISO"
echo "HOST=$(hostname)"

echo
echo "========== PRECHECK =========="

test -f "$SERVER" || {
    fail "server.py missing"
    exit 1
}

test -f "$SETTINGS_UI" || {
    fail "settings_ui.py missing"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv python missing"
    exit 1
}

echo "PRECHECK_OK"

echo
echo "========== BACKUP CURRENT =========="

cp -a "$SERVER" \
"$BACKUP_DIR/server.py.current"

cp -a "$SETTINGS_UI" \
"$BACKUP_DIR/settings_ui.py.current"

[ -f "$RENDERER" ] && \
cp -a "$RENDERER" \
"$BACKUP_DIR/page_renderer.py.current" || true

echo "CURRENT_BACKUP_OK"

echo
echo "========== FIND PASS8 BACKUP =========="

PASS8_BACKUP="$(
    find /root/3245 \
    -maxdepth 1 \
    -type d \
    -name 'phase1-pass8-settings-renderer-fix-backup-*' \
    | sort \
    | tail -n 1
)"

if [ -z "$PASS8_BACKUP" ]; then
    fail "pass8 backup not found"
    exit 1
fi

SAFE_UI="$PASS8_BACKUP/settings_ui.py.before"

if [ ! -f "$SAFE_UI" ]; then
    fail "settings_ui.py.before not found in pass8 backup"
    exit 1
fi

echo "PASS8_BACKUP=$PASS8_BACKUP"
echo "SAFE_UI=$SAFE_UI"

echo
echo "========== RESTORE SETTINGS_UI =========="

cp -a "$SAFE_UI" "$SETTINGS_UI"

echo "SETTINGS_UI_RESTORED"

echo
echo "========== COMPILE RESTORED FILE =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
app/panel/settings_ui.py

echo "RESTORED_COMPILE_OK"

echo
echo "========== CREATE SHARED RENDERER =========="

cat > "$RENDERER" <<'PY'
from __future__ import annotations

from aiohttp import web


def page(title: str, content: str) -> web.Response:
    html = f"""<!doctype html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
body {{
    margin: 0;
    font-family: sans-serif;
    background: #f6f7f9;
    color: #222;
}}
.wrap {{
    max-width: 1180px;
    margin: 0 auto;
    padding: 20px;
}}
.card {{
    background: #fff;
    border: 1px solid #e5e7eb;
    border-radius: 14px;
    padding: 18px;
    margin-bottom: 16px;
}}
</style>
</head>
<body>
<div class="wrap">
{content}
</div>
</body>
</html>"""

    return web.Response(
        text=html,
        content_type="text/html",
        charset="utf-8",
    )
PY

echo "SHARED_RENDERER_READY"

echo
echo "========== SAFE IMPORT PATCH =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path
import ast

path = Path("/opt/config-location/app/panel/settings_ui.py")
text = path.read_text(encoding="utf-8")

IMPORT_LINE = "from app.panel.page_renderer import page"

if IMPORT_LINE in text:
    print("IMPORT_ALREADY_PRESENT")
else:
    tree = ast.parse(text)

    lines = text.splitlines()

    insert_line = 0

    # Keep module docstring first if one exists.
    if (
        tree.body
        and isinstance(tree.body[0], ast.Expr)
        and isinstance(tree.body[0].value, ast.Constant)
        and isinstance(tree.body[0].value.value, str)
    ):
        insert_line = tree.body[0].end_lineno

    # Keep all __future__ imports before our import.
    for node in tree.body:
        if (
            isinstance(node, ast.ImportFrom)
            and node.module == "__future__"
        ):
            insert_line = max(insert_line, node.end_lineno)

    lines.insert(insert_line, IMPORT_LINE)

    text = "\n".join(lines) + "\n"

    # Verify that the result parses before writing.
    ast.parse(text)

    path.write_text(
        text,
        encoding="utf-8",
    )

    print(
        f"IMPORT_INSERTED_AT_LINE={insert_line + 1}"
    )
PY

echo
echo "========== VERIFY IMPORT =========="

grep -n \
'from app.panel.page_renderer import page' \
"$SETTINGS_UI"

grep -n \
'return page(' \
"$SETTINGS_UI"

echo
echo "========== COMPILE AFTER PATCH =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
app/panel/page_renderer.py \
app/panel/settings_ui.py \
app/panel/server.py

echo "COMPILE_OK"

echo
echo "========== IMPORT TEST =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.panel.page_renderer import page
from app.panel.settings_ui import settings_page
import app.panel.server

assert callable(page)
assert callable(settings_page)

print("IMPORT_TEST_OK")
PY

echo
echo "========== RENDERER TEST =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.panel.page_renderer import page

response = page(
    "Renderer Test",
    "<div>RENDERER_OK</div>",
)

assert response.status == 200
assert b"RENDERER_OK" in response.body

print("RENDERER_TEST_OK")
PY

echo
echo "========== SETTINGS ENGINE TEST =========="

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

print("SETTINGS_ENGINE_OK")
print("REVISION=", status["revision"])
PY

echo
echo "========== RESTART PANEL =========="

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
    echo
    echo "========== CURRENT JOURNAL =========="

    journalctl \
    -u "$SERVICE" \
    --since "$START_ISO" \
    --no-pager || true

    fail "panel failed to become ready"
    exit 1
fi

echo "PANEL_READY"

echo
echo "========== PORT 4040 TEST =========="

ss -lntp | grep ":${PORT}"

echo "PORT_4040_OK"

echo
echo "========== UNAUTH SETTINGS TEST =========="

SETTINGS_CODE="$(
    curl -sS \
    -o /tmp/pass9-settings.out \
    -w '%{http_code}' \
    http://127.0.0.1:${PORT}/settings \
    || true
)"

echo "SETTINGS_HTTP=$SETTINGS_CODE"

case "$SETTINGS_CODE" in
    200|302|303)
        echo "UNAUTH_SETTINGS_OK"
        ;;
    *)
        echo
        echo "========== SETTINGS BODY =========="

        cat \
        /tmp/pass9-settings.out \
        2>/dev/null || true

        echo
        echo "========== CURRENT JOURNAL =========="

        journalctl \
        -u "$SERVICE" \
        --since "$START_ISO" \
        --no-pager || true

        fail "settings route unhealthy"
        exit 1
        ;;
esac

echo
echo "========== CURRENT FATAL CHECK =========="

FATAL="$(
    journalctl \
    -u "$SERVICE" \
    --since "$START_ISO" \
    --no-pager 2>/dev/null \
    | grep -Ei \
    'Traceback|SyntaxError|NameError|PermissionError|ModuleNotFoundError|Internal Server Error' \
    || true
)"

if [ -n "$FATAL" ]; then
    echo "$FATAL"
    fail "fatal error detected after restart"
    exit 1
fi

echo "NO_CURRENT_FATAL_ERRORS"

echo
echo "========== FINAL HASHES =========="

sha256sum \
"$SERVER" \
"$SETTINGS_UI" \
"$RENDERER"

echo
echo "PHASE1_PASS9_SUCCESS"

RESULT="SUCCESS"
