#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/opt/config-location"

echo "================================================"
echo " PHASE 6 PASS 1B — RECOVERY DIAGNOSTIC"
echo "================================================"

echo
echo "========== [1/8] PROCESSES =========="

pgrep -af \
'phase6-pass1b|config-location-dev-run' \
|| true


echo
echo "========== [2/8] SERVICES =========="

for UNIT in \
  config-location-panel.service \
  config-location-country-worker.service \
  config-location-country-event-consumer.service \
  config-location-live-watch.service \
  config-location-live-reconcile.timer
do
    echo -n "$UNIT="
    systemctl is-active "$UNIT" 2>/dev/null || true
done


echo
echo "========== [3/8] PANEL STATUS =========="

systemctl status \
  config-location-panel.service \
  --no-pager -l \
  | tail -n 80 \
  || true


echo
echo "========== [4/8] PANEL JOURNAL =========="

journalctl \
  -u config-location-panel.service \
  -n 120 \
  --no-pager \
  || true


echo
echo "========== [5/8] SOURCE CONTRACT =========="

echo "--- http.py catalog references ---"

grep -nE \
'country_catalog|api/countries|build_country_catalog' \
"$PROJECT/app/publish/http.py" \
|| true

echo
echo "--- catalog.py ---"

if [ -f "$PROJECT/app/country/catalog.py" ]; then
    echo "CATALOG_FILE=YES"
    sed -n '1,260p' \
      "$PROJECT/app/country/catalog.py"
else
    echo "CATALOG_FILE=NO"
fi


echo
echo "========== [6/8] COMPILE =========="

set +e

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
  "$PROJECT/app/publish/http.py" \
  "$PROJECT/app/panel/server.py" \
  "$PROJECT/app/country/catalog.py" \
  2>&1

COMPILE_RC=$?

set -e

echo "COMPILE_RC=$COMPILE_RC"


echo
echo "========== [7/8] HTTP =========="

for PATH in \
  /sub/all \
  /sub/country/UNKNOWN \
  /sub/country/CONFLICT \
  /api/publish/status \
  /api/countries
do

    echo
    echo "--- $PATH ---"

    curl -sS \
      --max-time 10 \
      -D - \
      -o /tmp/p6p1b-recovery.body \
      "http://127.0.0.1:4040$PATH" \
      | sed -n '1,25p' \
      || true

done


echo
echo "========== [8/8] RECONCILE =========="

/usr/local/sbin/config-location-live-sync \
  || true

config-location-dev-status \
  || true

echo
echo "PHASE6_PASS1B_RECOVERY_DIAGNOSTIC_COMPLETE"
