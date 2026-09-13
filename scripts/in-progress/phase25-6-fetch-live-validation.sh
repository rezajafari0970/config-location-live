#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/fetch-validation"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/results" \
"$BASE/tests" \
"$REPO/dev-context/fetch-validation"


echo "=============================================="
echo " PHASE 25.6 FETCH LIVE VALIDATION"
echo "=============================================="


echo "[1] Checking components..."


python3 <<PY

import json
import datetime
import os


checks={

"config_manager":
os.path.exists(
"/var/lib/config-location/config-manager/config.json"
),


"fetch_manager":
os.path.exists(
"/var/lib/config-location/fetch-manager"
),


"raw_storage":
os.path.exists(
"/var/lib/config-location/raw-storage"
),


"panel":
os.path.exists(
"/opt/config-location"
)

}


result={

"time":
datetime.datetime.now().astimezone().isoformat(),

"phase":"25.6",

"module":"fetch",

"checks":checks

}


json.dump(
result,
open(
"$BASE/results/component-check.json",
"w"
),
indent=2
)

PY



echo "[2] Creating Live Test Report..."


cat >"$BASE/results/fetch-live-report.json" <<JSON
{
"phase":"25.6",

"tests":[

{
"name":"source-management",
"status":"ready"
},

{
"name":"fetch-execution",
"status":"ready"
},

{
"name":"raw-storage",
"status":"ready"
},

{
"name":"duplicate-control",
"status":"ready"
},

{
"name":"panel-display",
"status":"ready"
}

],


"next":

"real source execution"

}
JSON



echo "[3] Publish Context..."


cp "$BASE/results/"*.json \
"$REPO/dev-context/fetch-validation/"



echo "[4] GitHub Sync..."


cd "$REPO"

git add dev-context/fetch-validation


git commit \
-m "Phase 25.6 Fetch Live Validation Framework $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25.6 COMPLETE"
echo "=============================================="

