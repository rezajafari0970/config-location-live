#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

BASE="$DEV/panel-upgrade"

mkdir -p \
"$BASE/backup" \
"$BASE/api" \
"$BASE/ui" \
"$BASE/tests" \
"$REPO/dev-context/panel-upgrade"


echo "=============================================="
echo " PHASE 25.3.2 PANEL UPGRADE PREPARATION"
echo "=============================================="


echo "[1] Loading Panel Audit..."

AUDIT="$DEV/panel-real-audit/panel-real-audit.json"

if [ ! -f "$AUDIT" ]; then
    echo "ERROR: Panel audit missing"
    exit 1
fi


echo "[2] Creating API Contract..."


cat >"$BASE/api/fetch-panel-api.json" <<JSON
{
"version":1,

"endpoints":[

"/fetch/settings",

"/fetch/sources",

"/fetch/status"

],


"actions":[

"read",

"update",

"enable",

"disable"

]

}
JSON



echo "[3] Creating UI Contract..."


cat >"$BASE/ui/fetch-ui-schema.json" <<JSON
{
"pages":[

"source-management",

"fetch-settings",

"fetch-status"

],


"components":[

"table",

"forms",

"status-cards"

]

}
JSON



echo "[4] Test Plan..."

cat >"$BASE/tests/panel-test-plan.json" <<JSON
{
"tests":[

"open-panel",

"load-sources",

"change-setting",

"save-setting",

"verify-fetcher-read"

],

"rollback":true

}
JSON



echo "[5] Upgrade State..."

cat >"$BASE/panel-upgrade-state.json" <<JSON
{
"phase":"25.3.2",

"status":"prepared",

"core_panel_preserved":true,

"ready_for_patch":true

}
JSON



echo "[6] Publish Context..."

cp "$BASE/api/fetch-panel-api.json" \
"$REPO/dev-context/panel-upgrade/fetch-panel-api.json"

cp "$BASE/ui/fetch-ui-schema.json" \
"$REPO/dev-context/panel-upgrade/fetch-ui-schema.json"

cp "$BASE/tests/panel-test-plan.json" \
"$REPO/dev-context/panel-upgrade/panel-test-plan.json"

cp "$BASE/panel-upgrade-state.json" \
"$REPO/dev-context/panel-upgrade/status.json"



echo "[7] GitHub Sync..."

cd "$REPO"

git add dev-context/panel-upgrade


git commit \
-m "Phase 25.3.2 Panel Upgrade Preparation $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25.3.2 COMPLETE"
echo "=============================================="

