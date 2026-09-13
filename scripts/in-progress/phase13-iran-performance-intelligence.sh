#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/iran-intelligence"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/probes" \
"$BASE/profiles" \
"$BASE/policy" \
"$BASE/results" \
"$REPO/dev-context/iran-intelligence"


echo "=============================================="
echo " PHASE 13 IRAN PERFORMANCE INTELLIGENCE"
echo "=============================================="


cat >"$BASE/schema.json" <<'JSON'
{
"version":1,

"iran_result":{

"config_id":"",

"iran_score":0,

"metrics":{

"latency":0,

"download":0,

"upload":0,

"stability":0

},

"isp_scores":{},

"profile":""

}

}
JSON


cat >"$BASE/policy/score-policy.json" <<'JSON'
{
"version":1,

"weights":{

"latency":20,

"download":30,

"upload":25,

"stability":25

},


"mode":"configurable"

}
JSON


cat >"$BASE/profiles/isp-profiles.json" <<'JSON'
{
"profiles":[

"mci",

"mtn",

"rightel",

"weak-network"

]

}
JSON


cat >"$BASE/probes/probe-schema.json" <<'JSON'
{
"regions":[

"tehran",

"shiraz",

"mashhad",

"tabriz",

"isfahan"

]

}
JSON


cat >"$BASE/results/latest.json" <<'JSON'
{
"status":"initialized"
}
JSON



python3 <<PY

import json,datetime


data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"module":
"iran-performance-intelligence",


"features":[

"regional-probes",

"isp-profiles",

"weak-network-profile",

"iran-score"

]

}


json.dump(
data,
open(
"$REPO/dev-context/iran-intelligence/status.json",
"w"
),
indent=2
)

PY



cp "$BASE/schema.json" \
"$REPO/dev-context/iran-intelligence/schema.json"

cp "$BASE/policy/score-policy.json" \
"$REPO/dev-context/iran-intelligence/score-policy.json"

cp "$BASE/profiles/isp-profiles.json" \
"$REPO/dev-context/iran-intelligence/isp-profiles.json"

cp "$BASE/probes/probe-schema.json" \
"$REPO/dev-context/iran-intelligence/probe-schema.json"



echo "[GitHub Sync]"

cd "$REPO"

git add dev-context/iran-intelligence


git commit \
-m "Phase 13 Iran Performance Intelligence $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 13 COMPLETE"
echo "=============================================="

