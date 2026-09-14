#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase1-pass8-settings-renderer-fix"

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
echo " PHASE 1 PASS 8"
echo " SETTINGS RENDERER INTEGRATION FIX"
echo "================================================"

echo "START=$START_ISO"
echo "HOST=$(hostname)"

SERVER="$PROJECT/app/panel/server.py"
SETTINGS_UI="$PROJECT/app/panel/settings_ui.py"
RENDERER="$PROJECT/app/panel/page_renderer.py"

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
echo "========== BACKUP =========="

cp -a "$SERVER" "$BACKUP_DIR/server.py.before"
cp -a "$SETTINGS_UI" "$BACKUP_DIR/settings_ui.py.before"

[ -f "$RENDERER" ] && \
cp -a "$RENDERER" "$BACKUP_DIR/page_renderer.py.before" || true

echo "BACKUP_OK"

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
h1,h2,h3 {{
    margin-top: 0;
}}
input, select, textarea {{
    width: 100%;
    box-sizing: border-box;
    padding: 10px;
    border: 1px solid #d1d5db;
    border-radius: 8px;
}}
button {{
    padding: 10px 16px;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
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

echo "SHARED_RENDERER_CREATED"

echo
echo "========== PATCH SETTINGS_UI =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from pathlib import Path

path = Path("/opt/config-location/app/panel/settings_ui.py")
text = path.read_text(encoding="utf-8")

import_line = "from app.panel.page_renderer import page"

# remove old broken/commented imports if present
text = text.replace(
    "from app.panel.server import page",
    import_line
)

if import_line not in text:
    lines = text.splitlines()

    insert_at = 0
    while insert_at < len(lines):
        line = lines[insert_at].strip()

        if (
            line.startswith("from __future__")
            or line.startswith("import ")
            or line.startswith("from ")
            or line == ""
        ):
            insert_at += 1
            continue

        break

    lines.insert(insert_at, import_line)
    text = "\n".join(lines) + "\n"

path.write_text(text, encoding="utf-8")

print("SETTINGS_UI_RENDERER_IMPORT_OK")
PY

echo
echo "========== VERIFY PAGE REFERENCE =========="

grep -n \
-E 'page_renderer|return page\(' \
"$SETTINGS_UI"

echo
echo "========== COMPILE =========="

cd "$PROJECT"

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

assert callable(page)
assert callable(settings_page)

print("IMPORT_OK")
PY

echo
echo "========== RENDERER SELFTEST =========="

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.panel.page_renderer import page

r = page("Test", "<div>OK</div>")

assert r.status == 200
assert b"OK" in r.body

print("RENDERER_SELFTEST_OK")
PY

echo
echo "========== SETTINGS ENGINE TEST =========="

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.settings.engine import get_settings, get_settings_status

s = get_settings()
st = get_settings_status()

assert isinstance(s, dict)
assert st["revision"] >= 1

print("SETTINGS_ENGINE_OK")
print("REVISION=", st["revision"])
PY

echo
echo "========== RESTART PANEL =========="

systemctl restart "$SERVICE"

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
    journalctl \
    -u "$SERVICE" \
    --since "$START_ISO" \
    --no-pager || true

    fail "panel runtime did not become ready"
    exit 1
fi

echo "PANEL_READY"

echo
echo "========== UNAUTH SETTINGS TEST =========="

CODE="$(
    curl -sS \
    -o /tmp/pass8-settings.out \
    -w '%{http_code}' \
    http://127.0.0.1:${PORT}/settings \
    || true
)"

echo "SETTINGS_HTTP=$CODE"

case "$CODE" in
    200|302|303)
        echo "SETTINGS_ROUTE_OK"
        ;;
    *)
        cat /tmp/pass8-settings.out 2>/dev/null || true

        journalctl \
        -u "$SERVICE" \
        --since "$START_ISO" \
        --no-pager || true

        fail "settings route unhealthy"
        exit 1
        ;;
esac

echo
echo "========== CURRENT JOURNAL CHECK =========="

FATAL="$(
    journalctl \
    -u "$SERVICE" \
    --since "$START_ISO" \
    --no-pager 2>/dev/null \
    | grep -Ei \
    'Traceback|NameError|SyntaxError|PermissionError|Internal Server Error|ModuleNotFoundError' \
    || true
)"

if [ -n "$FATAL" ]; then
    echo "$FATAL"
    fail "fatal panel error detected"
    exit 1
fi

echo "NO_CURRENT_FATAL_ERRORS"

echo
echo "========== FINAL =========="

grep -n \
-E 'from app.panel.page_renderer import page|return page\(' \
"$SETTINGS_UI"

ss -lntp | grep ":${PORT}"

echo "PHASE1_PASS8_SUCCESS"

RESULT="SUCCESS"
