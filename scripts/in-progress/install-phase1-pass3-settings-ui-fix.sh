#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase1-pass3-settings-ui-fix"

PROJECT="/opt/config-location"
LOG_REPO="/root/project-log"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"

RUN_DIR="$LOG_REPO/executions/$DATE"
REPORT_DIR="$LOG_REPO/reports"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"

BACKUP="/root/3245/${PHASE}-backup-${TS}"

mkdir -p \
"$RUN_DIR" \
"$REPORT_DIR" \
"$BACKUP"


exec > >(tee "$LOG") 2>&1


RESULT="SUCCESS"
ERRORS=""


fail()
{
 RESULT="FAILED"
 ERRORS="${ERRORS}\n$1"
 echo "ERROR: $1"
}


echo "=============================================="
echo " PHASE 1 PASS 3"
echo " SETTINGS UI STABILIZATION"
echo "=============================================="


echo
echo "START:"
date -Is


################################################
# BACKUP
################################################

echo "========== BACKUP =========="


cp -a \
"$PROJECT/app/panel/server.py" \
"$BACKUP/"


cp -a \
"$PROJECT/app/panel/settings_ui.py" \
"$BACKUP/" \
2>/dev/null || true



################################################
# CREATE SAFE RENDERER
################################################

echo "========== CREATE UI RENDERER =========="


cat > "$PROJECT/app/panel/ui_renderer.py" <<'PY'
from __future__ import annotations


import html


def render_page(
    title: str,
    content: str
):

    return f"""
<!doctype html>

<html>

<head>

<meta charset="utf-8">

<title>{html.escape(title)}</title>


<style>

body {{
font-family: sans-serif;
background:#f5f7fb;
padding:20px;
}}

.card {{
background:white;
border-radius:12px;
padding:20px;
margin-bottom:15px;
box-shadow:0 2px 8px #ddd;
}}

input {{
width:100%;
padding:10px;
margin:8px 0;
}}

button {{
padding:12px 20px;
border:0;
border-radius:8px;
background:#2563eb;
color:white;
}}

</style>


</head>


<body>


<h1>
{html.escape(title)}
</h1>


{content}


</body>

</html>
"""
PY



################################################
# FIX SETTINGS UI IMPORT
################################################

echo "========== PATCH SETTINGS UI =========="


python3 <<'PY'

from pathlib import Path


p=Path(
"/opt/config-location/app/panel/settings_ui.py"
)


t=p.read_text(
encoding="utf-8"
)


t=t.replace(
"from app.panel.server import page",
"from app.panel.ui_renderer import render_page"
)


t=t.replace(
"return page(",
"return web.Response(text=render_page("
)


p.write_text(
t,
encoding="utf-8"
)

PY



################################################
# COMPILE
################################################

echo "========== COMPILE =========="


cd "$PROJECT"


PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
app/panel/ui_renderer.py \
app/panel/settings_ui.py \
|| fail "compile failed"


echo "COMPILE_OK"



################################################
# IMPORT TEST
################################################

echo "========== IMPORT TEST =========="


PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-c "
from app.panel.settings_ui import settings_page
print('SETTINGS_UI_IMPORT_OK')
" \
|| fail "import failed"



################################################
# RESTART
################################################

echo "========== PANEL RESTART =========="


systemctl restart \
config-location-panel.service \
|| fail "restart failed"


sleep 3


systemctl is-active \
config-location-panel.service \
|| fail "panel inactive"



################################################
# HTTP TEST
################################################

echo "========== HTTP TEST =========="


curl -I \
http://127.0.0.1:4040/settings \
|| fail "settings route failed"



################################################
# REPORT
################################################

cat > "$REPORT" <<REPORT

CONFIG LOCATION REPORT

Phase:
$PHASE

Result:
$RESULT

Time:
$(date -Is)

Backup:
$BACKUP

Log:
$LOG

Errors:
$ERRORS

REPORT



################################################
# GIT
################################################

echo "========== GIT SYNC =========="


cd "$LOG_REPO"

git add .


git commit \
-m "Phase execution $PHASE $TS" \
|| true


git push origin main \
|| true



echo
echo "=============================================="
echo " COMPLETE"
echo "=============================================="

echo "RESULT:"
echo "$RESULT"

echo "LOG:"
echo "$LOG"

echo "REPORT:"
echo "$REPORT"


if [ "$RESULT" != "SUCCESS" ]; then
 exit 1
fi

