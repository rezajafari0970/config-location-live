#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CORE="/opt/config-location"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

BASE="$DEV/fetch-panel-upgrade"

mkdir -p \
"$BASE/backup" \
"$BASE/patch-plan" \
"$REPO/dev-context/fetch-panel-upgrade"


echo "=============================================="
echo " PHASE 25.2.2 FETCH + PANEL SAFE UPGRADE"
echo "=============================================="


echo "[1] Core Snapshot..."

tar czf \
"$BASE/backup/core-before-fetch-panel-$(date +%Y%m%d-%H%M%S).tar.gz" \
"$CORE" \
2>/dev/null || true


echo "[2] Loading Audit..."

AUDIT="$DEV/fetch-panel-integration/fetch-panel-audit.json"


if [ ! -f "$AUDIT" ]; then
    echo "ERROR: Integration audit not found"
    exit 1
fi


echo "[3] Creating Safe Upgrade Plan..."


python3 <<PY

import json,datetime


with open("$AUDIT") as f:
    audit=json.load(f)


plan={

"time":
datetime.datetime.now().astimezone().isoformat(),


"phase":"25.2.2",


"mode":
"safe-adapter-upgrade",


"targets":{

"fetcher":

audit.get("fetch_files",[])[:20],


"panel":

audit.get("panel_files",[])[:20]

},


"changes":[

"config-manager-binding",

"source-manager-binding",

"raw-storage-hook",

"panel-source-control"

],


"rules":[

"do-not-rewrite-core",

"preserve-existing-behavior",

"rollback-enabled"

]

}


json.dump(
plan,
open(
"$BASE/patch-plan/upgrade-plan.json",
"w"
),
indent=2,
ensure_ascii=False
)

PY


echo "[4] Creating Integration Config..."


mkdir -p \
/var/lib/config-location/fetch-integration/runtime


cat >/var/lib/config-location/fetch-integration/runtime/fetch-upgrade-state.json <<JSON
{
"version":1,

"mode":"integration",

"fetcher_core":"preserved",

"panel_core":"preserved",

"config_manager":"enabled",

"source_manager":"enabled",

"raw_storage_hook":"enabled"

}
JSON


echo "[5] Publishing Context..."


cp "$BASE/patch-plan/upgrade-plan.json" \
"$REPO/dev-context/fetch-panel-upgrade/upgrade-plan.json"


cp /var/lib/config-location/fetch-integration/runtime/fetch-upgrade-state.json \
"$REPO/dev-context/fetch-panel-upgrade/fetch-upgrade-state.json"


echo "[6] GitHub Sync..."

cd "$REPO"

git add dev-context/fetch-panel-upgrade


git commit \
-m "Phase 25.2.2 Fetch Panel Safe Upgrade Plan $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25.2.2 COMPLETE"
echo "=============================================="

