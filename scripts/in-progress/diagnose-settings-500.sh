#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase1-settings-authenticated-500-diagnostic"
PROJECT="/opt/config-location"
REPO="/root/project-log"
DATE="$(date +%Y-%m-%d)"
TS="$(date +%Y%m%d-%H%M%S)"

DIR="$REPO/diagnostics/$DATE"
OUT="$DIR/${PHASE}-${TS}.txt"

mkdir -p "$DIR"

{
echo "================================================"
echo " SETTINGS AUTHENTICATED 500 DIAGNOSTIC"
echo "================================================"
echo
echo "TIME=$(date -Is)"
echo "HOST=$(hostname)"

echo
echo "========== SERVICE =========="
systemctl status config-location-panel.service --no-pager -l || true

echo
echo "========== PORT =========="
ss -lntp | grep ':4040' || true

echo
echo "========== JOURNAL LAST 10 MIN =========="
journalctl \
  -u config-location-panel.service \
  --since "-10 minutes" \
  --no-pager \
  -o short-precise || true

echo
echo "========== TRACEBACK / ERROR FILTER =========="
journalctl \
  -u config-location-panel.service \
  --since "-10 minutes" \
  --no-pager \
| grep -nEi \
'Traceback|Error handling request|Exception|PermissionError|TypeError|ValueError|KeyError|AttributeError|NameError|500|settings_page|settings_ui|settings.engine' \
|| true

echo
echo "========== SETTINGS_UI AROUND HANDLER =========="
grep -n \
  -E 'async def settings_page|def settings_page|install_settings_routes|get_settings|render|web.Response' \
  "$PROJECT/app/panel/settings_ui.py" || true

echo
echo "========== SETTINGS_UI 600-760 =========="
nl -ba "$PROJECT/app/panel/settings_ui.py" \
| sed -n '600,760p' || true

echo
echo "========== SERVER SETTINGS ROUTES =========="
grep -n \
  -E 'settings|install_settings_routes|auth_middleware' \
  "$PROJECT/app/panel/server.py" || true

echo
echo "========== SETTINGS ENGINE STATUS AS CONFIGLOC =========="
cd "$PROJECT"

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
from app.settings.engine import get_settings, get_settings_status

s = get_settings()
st = get_settings_status()

print("READ_OK")
print("revision =", st.get("revision"))
print("checksum =", st.get("checksum"))
print("top_level_keys =", sorted(s.keys()))
PY

echo
echo "========== PERMISSIONS =========="
namei -l /var/lib/config-location/settings/settings.json || true
namei -l /run/config-location/settings.lock || true

echo
echo "========== FILE HASHES =========="
sha256sum \
"$PROJECT/app/panel/server.py" \
"$PROJECT/app/panel/settings_ui.py" \
"$PROJECT/app/settings/engine.py" || true

echo
echo "========== PYTHON COMPILE =========="
PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
"$PROJECT/app/panel/server.py" \
"$PROJECT/app/panel/settings_ui.py" \
"$PROJECT/app/settings/engine.py" \
&& echo "COMPILE_OK"

echo
echo "========== END =========="
date -Is

} 2>&1 | tee "$OUT"

cd "$REPO"

git add "$OUT"

git commit \
  -m "Diagnostic authenticated settings 500 $TS" \
  || true

git push origin main

echo
echo "=============================================="
echo "DIAGNOSTIC COMPLETE"
echo "$OUT"
echo "=============================================="
