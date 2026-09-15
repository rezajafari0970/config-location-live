#!/usr/bin/env bash
set -Eeuo pipefail

R=/opt/config-location

echo "======================================================"
echo " PANEL-A1 FULL PANEL AUDIT"
echo "======================================================"

echo
echo "=== 1. PANEL SERVICE ==="

systemctl cat \
config-location-panel.service

echo
echo "=== 2. PANEL PROCESS ==="

PID=$(
    systemctl show \
    config-location-panel.service \
    -p MainPID \
    --value
)

echo "PID=$PID"

test "$PID" -gt 0

ps -fp "$PID"

echo
echo "=== 3. LISTEN PORT ==="

ss -lntp | grep "$PID" || true

echo
echo "=== 4. PROJECT PANEL FILES ==="

find "$R" \
-type f \
\( \
    -iname '*panel*' \
    -o -iname '*.html' \
    -o -iname '*.css' \
    -o -iname '*.js' \
    -o -iname '*server*.py' \
    -o -iname '*web*.py' \
    -o -iname '*api*.py' \
\) \
-print \
| sort

echo
echo "=== 5. COMPLETE APP TREE ==="

find "$R/app" \
-maxdepth 4 \
-type f \
-print \
| sort

echo
echo "=== 6. HTTP ROUTES ==="

grep -RIn \
--include='*.py' \
-E \
'@(app|router)\.(get|post|put|delete|patch)|route\(|add_route|do_GET|do_POST|BaseHTTPRequestHandler|HTTPServer|ThreadingHTTPServer' \
"$R/app" \
"$R" \
2>/dev/null \
| head -n 3000

echo
echo "=== 7. SUBSCRIPTION ENDPOINTS ==="

grep -RIn \
--include='*.py' \
--include='*.html' \
--include='*.js' \
-E \
'/sub/|sub/all|subscription|country|unknown|unresolved|open|import' \
"$R/app" \
2>/dev/null \
| head -n 3000

echo
echo "=== 8. PANEL SETTINGS / CONTROLS ==="

grep -RIn \
--include='*.py' \
--include='*.html' \
--include='*.js' \
-E \
'lifetime|interval|fetch|health|restart|start|stop|service|settings|source|worker|queue' \
"$R/app" \
2>/dev/null \
| head -n 3000

echo
echo "=== 9. PANEL SOURCE FILE CONTENT ==="

UNIT_EXEC=$(
    systemctl show \
    config-location-panel.service \
    -p ExecStart \
    --value
)

echo "EXECSTART=$UNIT_EXEC"

echo
echo "=== 10. LIKELY PANEL PYTHON FILES ==="

grep -RIl \
--include='*.py' \
-E \
'4040|HTTPServer|Flask|FastAPI|uvicorn|panel' \
"$R/app" \
"$R" \
2>/dev/null \
| sort \
| while read -r F
do
    echo
    echo "############################################"
    echo "FILE=$F"
    echo "############################################"

    cat "$F"
done

echo
echo "=== 11. LOCAL HTTP SMOKE ==="

curl -sS \
--max-time 10 \
-D - \
http://127.0.0.1:4040/ \
-o /tmp/panel-a1-body.txt \
|| true

echo
echo "--- BODY FIRST 120 LINES ---"

sed -n '1,120p' \
/tmp/panel-a1-body.txt \
2>/dev/null || true

echo
echo "=== 12. PRODUCTION SAFETY ==="

X=$(
    systemctl is-active \
    config-location-panel.service
)

echo "PANEL_SERVICE=$X"

test "$X" = active

echo
echo "======================================================"
echo "PANEL_A1_AUDIT=PASS"
echo "PRODUCTION_CHANGED=NO"
echo "NEXT=PANEL-A2-GAP-MAP"
echo "======================================================"
