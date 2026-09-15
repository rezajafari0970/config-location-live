#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== PANEL UNIT ==="
systemctl cat config-location-panel.service

echo
echo "=== PANEL EXECSTART ==="

systemctl show \
config-location-panel.service \
-p ExecStart \
--value

echo
echo "=== PANEL PYTHON CANDIDATES ==="

find /opt/config-location \
-type f \
-name '*.py' \
-print0 |
xargs -0 grep -IlE \
'4040|ThreadingHTTPServer|HTTPServer|BaseHTTPRequestHandler|Flask|FastAPI|uvicorn' \
| sort

echo
echo "=== PANEL SOURCE ==="

find /opt/config-location \
-type f \
-name '*.py' \
-print0 |
xargs -0 grep -IlE \
'4040|ThreadingHTTPServer|HTTPServer|BaseHTTPRequestHandler' \
| sort -u \
| while read -r F
do
    echo
    echo "##################################################"
    echo "FILE=$F"
    echo "##################################################"
    cat "$F"
done

echo
echo "PANEL_A1_SOURCE_DUMP=PASS"
