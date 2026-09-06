#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/classifier"
RAW="/var/lib/config-location/raw-storage"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/rules" \
"$BASE/results" \
"$REPO/dev-context/classifier"


echo "=============================================="
echo " PHASE 7 XRAY CLASSIFIER FOUNDATION"
echo "=============================================="


cat >"$BASE/rules/protocol-rules.json" <<JSON
{
"version":1,

"protocols":{

"vless":"vless://",

"vmess":"vmess://",

"trojan":"trojan://",

"shadowsocks":"ss://"

},


"json_detection":{

"xray":[
"outbounds",
"inbounds",
"routing"
],

"custom":true

}

}
JSON



cat >"$BASE/results/schema.json" <<JSON
{
"id":"",

"raw_hash":"",

"type":"",

"confidence":0,

"source":"",

"time":""

}
JSON



python3 <<PY

import json,datetime


data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"module":"xray-classifier",

"supported":[

"vless",

"vmess",

"trojan",

"shadowsocks",

"xray_json",

"custom_json"

],

"rules":
"$BASE/rules/protocol-rules.json"

}


json.dump(
data,
open(
"$REPO/dev-context/classifier/classifier-status.json",
"w"
),
indent=2
)

PY


cp "$BASE/rules/protocol-rules.json" \
"$REPO/dev-context/classifier/rules.json"

cp "$BASE/results/schema.json" \
"$REPO/dev-context/classifier/result-schema.json"



echo "[GitHub Sync]"

cd "$REPO"

git add dev-context/classifier


git commit \
-m "Phase 7 Xray Classifier Foundation $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 7 COMPLETE"
echo "=============================================="

