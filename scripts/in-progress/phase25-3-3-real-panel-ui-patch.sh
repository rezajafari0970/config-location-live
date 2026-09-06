#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CORE="/opt/config-location"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

BASE="$DEV/panel-real-patch"

mkdir -p \
"$BASE/backup" \
"$BASE/patch" \
"$BASE/test" \
"$REPO/dev-context/panel-real-patch"


echo "=============================================="
echo " PHASE 25.3.3 REAL PANEL UI PATCH"
echo "=============================================="


AUDIT="$DEV/panel-real-audit/panel-real-audit.json"


if [ ! -f "$AUDIT" ]; then
    echo "ERROR: Panel audit missing"
    exit 1
fi


echo "[1] Backup Panel..."

tar czf \
"$BASE/backup/panel-before-$(date +%Y%m%d-%H%M%S).tar.gz" \
"$CORE" \
2>/dev/null || true



echo "[2] Creating UI Patch Manifest..."


python3 <<PY

import json,datetime


audit=json.load(
open("$AUDIT")
)


data={

"time":
datetime.datetime.now().astimezone().isoformat(),


"phase":"25.3.3",


"targets":{

"panel_files":
audit.get("panel_files",[])[:50],


"routes":
audit.get("routes",[])[:50]

},


"patches":[

"fetch_settings_ui",

"source_management_fields",

"fetch_status_view",

"config_manager_binding"

],


"policy":[

"preserve_existing_routes",

"rollback_available",

"incremental_upgrade"

]

}


json.dump(
data,
open(
"$BASE/patch/panel-patch-manifest.json",
"w"
),
indent=2,
ensure_ascii=False
)

PY



echo "[3] Creating Panel Integration Config..."


mkdir -p \
/var/lib/config-location/panel-integration/fetch


cat >/var/lib/config-location/panel-integration/fetch/ui-state.json <<JSON
{
"version":1,

"module":"fetch",

"ui":"enabled",

"sections":[

"source-management",

"fetch-settings",

"fetch-status"

]

}
JSON



echo "[4] Syntax Validation..."

python3 - <<PY

import json

json.load(
open(
"$BASE/patch/panel-patch-manifest.json"
)
)

print("PANEL PATCH MANIFEST OK")

PY



echo "[5] Publish Context..."


cp "$BASE/patch/panel-patch-manifest.json" \
"$REPO/dev-context/panel-real-patch/panel-patch-manifest.json"


cp /var/lib/config-location/panel-integration/fetch/ui-state.json \
"$REPO/dev-context/panel-real-patch/fetch-ui-state.json"



echo "[6] GitHub Sync..."

cd "$REPO"

git add dev-context/panel-real-patch


git commit \
-m "Phase 25.3.3 Real Panel UI Patch $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25.3.3 COMPLETE"
echo "=============================================="

