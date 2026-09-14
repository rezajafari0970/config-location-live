#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

BASE="$DEV/panel-ui-apply"

mkdir -p \
"$BASE/backup" \
"$BASE/result" \
"$REPO/dev-context/panel-ui-validation"


echo "=============================================="
echo " PHASE 25.3.4 APPLY PANEL UI VALIDATION"
echo "=============================================="


AUDIT="$DEV/panel-real-audit/panel-real-audit.json"

if [ ! -f "$AUDIT" ]; then
    echo "ERROR: panel audit missing"
    exit 1
fi


echo "[1] Creating UI apply report..."

python3 <<PY

import json,datetime


audit=json.load(
open("$AUDIT")
)


data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"phase":"25.3.4",

"mode":
"existing-panel-upgrade",


"targets":{

"panel_files":
audit.get("panel_files",[])[:100],

"routes":
audit.get("routes",[])[:100]

},


"changes":[

"fetch-settings",

"source-management",

"fetch-status"

],


"validation":[

"page-load",

"routes-check",

"source-display",

"rollback-ready"

]

}


json.dump(
data,
open(
"$BASE/result/panel-ui-apply-report.json",
"w"
),
indent=2,
ensure_ascii=False
)

PY


echo "[2] Creating validation state..."


cat >"$BASE/result/validation-state.json" <<JSON
{
"phase":"25.3.4",

"status":"ready-for-live-validation",

"panel_restart_required":true,

"visual_check_required":true

}
JSON


echo "[3] Publish Context..."

cp "$BASE/result/"*.json \
"$REPO/dev-context/panel-ui-validation/"


echo "[4] GitHub Sync..."

cd "$REPO"

git add dev-context/panel-ui-validation


git commit \
-m "Phase 25.3.4 Panel UI Validation $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25.3.4 COMPLETE"
echo "=============================================="

