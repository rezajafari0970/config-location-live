#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/publish"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/policy" \
"$BASE/results" \
"$BASE/cache" \
"$REPO/dev-context/publish"


echo "=============================================="
echo " PHASE 17 PUBLISH ENGINE FOUNDATION"
echo "=============================================="


cat >"$BASE/schema.json" <<'JSON'
{
"version":1,

"publish_result":{

"subscription":"",

"generated_at":"",

"count":0,

"filters":{

"healthy":true,

"active":true,

"ranked":true

}

}

}
JSON



cat >"$BASE/policy/publish-policy.json" <<'JSON'
{
"version":1,

"outputs":[

"all",

"country",

"best"

],


"rules":{

"only_healthy":true,

"only_active":true,

"remove_expired":true

},


"cache":"enabled"

}
JSON



cat >"$BASE/results/latest.json" <<'JSON'
{
"status":"initialized",

"publish_ready":true
}
JSON



python3 <<PY

import json,datetime


data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"module":
"publish-engine",


"features":[

"subscription-builder",

"country-output",

"best-output",

"filtering",

"cache"

]

}


json.dump(
data,
open(
"$REPO/dev-context/publish/status.json",
"w"
),
indent=2
)

PY



cp "$BASE/schema.json" \
"$REPO/dev-context/publish/schema.json"


cp "$BASE/policy/publish-policy.json" \
"$REPO/dev-context/publish/publish-policy.json"



echo "[GitHub Sync]"

cd "$REPO"

git add dev-context/publish


git commit \
-m "Phase 17 Publish Engine Foundation $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 17 COMPLETE"
echo "=============================================="

