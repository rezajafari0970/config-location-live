#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/parser"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/protocols" \
"$BASE/schemas" \
"$BASE/results" \
"$REPO/dev-context/parser"


echo "=============================================="
echo " PHASE 8 XRAY PARSER FOUNDATION"
echo "=============================================="


cat >"$BASE/parser-config.json" <<JSON
{
"version":1,

"supported":[

"vless",

"vmess",

"trojan",

"shadowsocks",

"xray_json",

"custom_json"

],


"rules":{

"preserve_raw":true,

"normalize_output":true

}

}
JSON



cat >"$BASE/schemas/normalized-config.json" <<JSON
{
"id":"",

"type":"",

"server":"",

"port":"",

"security":"",

"transport":{},

"tls":{},

"reality":{},

"raw_reference":""

}
JSON



for P in \
vless \
vmess \
trojan \
shadowsocks \
xray_json \
custom_json
do

cat >"$BASE/protocols/$P.json" <<JSON
{
"type":"$P",

"enabled":true,

"parser":"planned"
}
JSON

done



python3 <<PY

import json,datetime


data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"module":"xray-parser",

"supported":[

"vless",

"vmess",

"trojan",

"shadowsocks",

"xray_json",

"custom_json"

],

"raw_preservation":True,

"normalized_model":True

}


json.dump(
data,
open(
"$REPO/dev-context/parser/parser-status.json",
"w"
),
indent=2
)

PY



cp "$BASE/parser-config.json" \
"$REPO/dev-context/parser/parser-config.json"

cp "$BASE/schemas/normalized-config.json" \
"$REPO/dev-context/parser/normalized-schema.json"



echo "[GitHub Sync]"

cd "$REPO"

git add dev-context/parser


git commit \
-m "Phase 8 Xray Parser Foundation $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 8 COMPLETE"
echo "=============================================="

