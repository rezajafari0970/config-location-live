#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/runtime"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/workspaces" \
"$BASE/results" \
"$BASE/logs" \
"$REPO/dev-context/runtime"


echo "=============================================="
echo " PHASE 9 XRAY RUNTIME FOUNDATION"
echo "=============================================="


cat >"$BASE/runtime-policy.json" <<JSON
{
"version":1,

"workspace":

"/var/lib/config-location/runtime/workspaces",


"port_pool":{

"start":10000,

"end":20000

},


"cleanup":{

"enabled":true,

"timeout":"auto"

}

}
JSON


cat >"$BASE/runtime-schema.json" <<JSON
{
"id":"",

"status":"",

"pid":"",

"port":"",

"workspace":"",

"started":"",

"error":""

}
JSON


cat >"$BASE/port-policy.json" <<JSON
{
"mode":"dynamic",

"range":[10000,20000],

"collision_check":true
}
JSON



python3 <<PY

import json,datetime


data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"module":"xray-runtime",

"status":"foundation-ready",

"features":[

"sandbox",

"process-manager",

"port-manager",

"cleanup",

"runtime-result"

]

}


json.dump(
data,
open(
"$REPO/dev-context/runtime/runtime-status.json",
"w"
),
indent=2
)

PY



cp "$BASE/runtime-policy.json" \
"$REPO/dev-context/runtime/runtime-policy.json"

cp "$BASE/runtime-schema.json" \
"$REPO/dev-context/runtime/runtime-schema.json"

cp "$BASE/port-policy.json" \
"$REPO/dev-context/runtime/port-policy.json"



echo "[GitHub Sync]"

cd "$REPO"

git add dev-context/runtime


git commit \
-m "Phase 9 Xray Runtime Foundation $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 9 COMPLETE"
echo "=============================================="

