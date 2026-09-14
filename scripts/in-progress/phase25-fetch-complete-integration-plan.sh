#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CORE="/opt/config-location"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

BASE="$DEV/fetch-complete"

mkdir -p \
"$BASE/backup" \
"$BASE/backend" \
"$BASE/panel" \
"$BASE/tests" \
"$BASE/validation" \
"$REPO/dev-context/fetch-complete"


echo "=============================================="
echo " PHASE 25 FETCH COMPLETE INTEGRATION PLAN"
echo "=============================================="


echo "[1] Snapshot Core..."

tar czf \
"$BASE/backup/fetch-before-integration-$(date +%Y%m%d-%H%M%S).tar.gz" \
"$CORE" \
2>/dev/null || true


echo "[2] Backend Integration Contract..."

cat >"$BASE/backend/fetch-contract.json" <<JSON
{
"version":1,

"module":"fetch",

"connections":[

"config-manager",

"source-manager",

"raw-storage",

"unified-config-model"

],


"rules":[

"preserve-existing-fetcher",

"no-second-fetch-core"

]

}
JSON


echo "[3] Panel Contract..."

cat >"$BASE/panel/fetch-panel-contract.json" <<JSON
{
"version":1,

"pages":[

"sources",

"fetch-settings",

"fetch-status"

],


"controls":[

"enable-source",

"disable-source",

"priority",

"interval",

"timeout",

"retry"

]

}
JSON


echo "[4] End-to-End Test Plan..."

cat >"$BASE/tests/fetch-e2e-test.json" <<JSON
{
"steps":[

"create-source",

"save-from-panel",

"fetch-run",

"raw-store-check",

"result-check",

"panel-display"

],


"success_required":true

}
JSON


echo "[5] Production Validation..."

cat >"$BASE/validation/fetch-validation.json" <<JSON
{
"checks":[

"service-running",

"error-handling",

"duplicate-control",

"rollback",

"resource-usage"

]

}
JSON


echo "[6] Dev Context..."

cp "$BASE/backend/fetch-contract.json" \
"$REPO/dev-context/fetch-complete/fetch-contract.json"

cp "$BASE/panel/fetch-panel-contract.json" \
"$REPO/dev-context/fetch-complete/fetch-panel-contract.json"

cp "$BASE/tests/fetch-e2e-test.json" \
"$REPO/dev-context/fetch-complete/fetch-e2e-test.json"

cp "$BASE/validation/fetch-validation.json" \
"$REPO/dev-context/fetch-complete/fetch-validation.json"


echo "[7] GitHub Sync..."

cd "$REPO"

git add dev-context/fetch-complete


git commit \
-m "Phase 25 Fetch Complete Integration Plan $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25 PLAN COMPLETE"
echo "=============================================="

