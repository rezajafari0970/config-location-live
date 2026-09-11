#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/fetch-finalization"
REPO="/var/lib/config-location/devlog-github/repo"
DEV="/var/lib/config-location/dev-assistant-v3"

mkdir -p \
"$BASE/panel" \
"$BASE/tests" \
"$BASE/validation" \
"$REPO/dev-context/fetch-finalization"


echo "=============================================="
echo " PHASE 25.3-25.5 FETCH COMPLETE FINALIZATION"
echo "=============================================="


echo "[1] Panel Integration Contract"


cat >"$BASE/panel/fetch-panel.json" <<'JSON'
{
"version":1,

"pages":[

"sources",

"fetch-settings",

"fetch-status"

],


"source_controls":[

"add",

"edit",

"enable",

"disable",

"priority"

],


"settings":[

"interval",

"timeout",

"retry",

"worker_mode"

]

}
JSON



echo "[2] E2E Test Definition"


cat >"$BASE/tests/fetch-e2e.json" <<'JSON'
{
"flow":[

"panel_create_source",

"config_manager_update",

"fetch_execution",

"raw_storage_write",

"result_record",

"panel_refresh"

],


"success_required":true

}
JSON



echo "[3] Production Validation"


cat >"$BASE/validation/fetch-production.json" <<'JSON'
{
"checks":[

"service_health",

"source_loading",

"duplicate_detection",

"raw_storage",

"error_handling",

"restart"

],


"rollback":

true

}
JSON



echo "[4] Create Fetch Completion State"


cat >"$BASE/fetch-final-state.json" <<JSON
{
"phase":"25",

"module":"fetch",

"status":"integration_ready",

"backend":true,

"panel":true,

"e2e_test_defined":true,

"production_validation_defined":true

}
JSON



echo "[5] Publish Dev Context"


cp "$BASE/panel/fetch-panel.json" \
"$REPO/dev-context/fetch-finalization/fetch-panel.json"

cp "$BASE/tests/fetch-e2e.json" \
"$REPO/dev-context/fetch-finalization/fetch-e2e.json"

cp "$BASE/validation/fetch-production.json" \
"$REPO/dev-context/fetch-finalization/fetch-production.json"

cp "$BASE/fetch-final-state.json" \
"$REPO/dev-context/fetch-finalization/status.json"



echo "[6] GitHub Sync"


cd "$REPO"

git add dev-context/fetch-finalization


git commit \
-m "Phase 25 Fetch Complete Finalization $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25 FETCH COMPLETE"
echo "=============================================="

