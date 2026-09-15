#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/parser-integration"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/adapter" \
"$BASE/mapping" \
"$BASE/validation" \
"$BASE/backup" \
"$REPO/dev-context/parser-integration"


echo "=============================================="
echo " PHASE 24 PARSER INTEGRATION"
echo "=============================================="


echo "[1] Backup..."

tar czf \
"$BASE/backup/parser-integration-$(date +%Y%m%d-%H%M%S).tar.gz" \
/opt/config-location \
2>/dev/null || true



echo "[2] Parser Adapter..."

cat >"$BASE/adapter/parser-adapter.json" <<'JSON'
{
"version":1,

"mode":"compatibility",

"input":"raw-config",

"output":"unified-config-model",

"preserve_raw":true

}
JSON



echo "[3] Classifier Mapping..."

cat >"$BASE/mapping/classifier-parser-map.json" <<'JSON'
{
"routes":{

"vless":"vless-parser",

"vmess":"vmess-parser",

"trojan":"trojan-parser",

"ss":"ss-parser",

"xray_json":"json-parser",

"custom_json":"custom-handler"

}

}
JSON



echo "[4] Unified Output Schema..."

cat >"$BASE/mapping/unified-parser-output.json" <<'JSON'
{
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



echo "[5] Validation Policy..."

cat >"$BASE/validation/validation-policy.json" <<'JSON'
{
"checks":[

"required-fields",

"schema",

"raw-preservation",

"hash"

],

"on_failure":

"reject-record"

}
JSON



echo "[6] Dev Context..."

python3 <<PY

import json,datetime


data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"phase":24,

"module":"parser-integration",

"features":[

"parser-adapter",

"classifier-routing",

"unified-output",

"validation",

"raw-preservation"

]

}


json.dump(
data,
open(
"$REPO/dev-context/parser-integration/status.json",
"w"
),
indent=2
)

PY



cp "$BASE/adapter/parser-adapter.json" \
"$REPO/dev-context/parser-integration/parser-adapter.json"

cp "$BASE/mapping/classifier-parser-map.json" \
"$REPO/dev-context/parser-integration/classifier-parser-map.json"

cp "$BASE/validation/validation-policy.json" \
"$REPO/dev-context/parser-integration/validation-policy.json"



echo "[7] GitHub Sync..."

cd "$REPO"

git add dev-context/parser-integration


git commit \
-m "Phase 24 Parser Integration $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 24 COMPLETE"
echo "=============================================="

