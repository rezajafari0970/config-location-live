#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/fetch-integration"
REPO="/var/lib/config-location/devlog-github/repo"
DEV="/var/lib/config-location/dev-assistant-v3"

mkdir -p \
"$BASE/adapter" \
"$BASE/source" \
"$BASE/storage" \
"$BASE/dedup" \
"$BASE/backup" \
"$REPO/dev-context/fetch-integration"


echo "=============================================="
echo " PHASE 23 FETCH INTEGRATION"
echo "=============================================="


echo "[1] Pre-change backup..."

tar czf \
"$BASE/backup/fetch-integration-$(date +%Y%m%d-%H%M%S).tar.gz" \
/opt/config-location \
2>/dev/null || true



echo "[2] Fetch Adapter..."

cat >"$BASE/adapter/fetch-adapter.json" <<'JSON'
{
"version":1,

"mode":"compatibility",

"input":"existing-fetcher",

"output":"unified-config-model",

"preserve_raw":true

}
JSON



echo "[3] Source Manager Model..."

cat >"$BASE/source/source-schema.json" <<'JSON'
{
"id":"",

"url":"",

"type":"",

"enabled":true,

"priority":0,

"last_fetch":"",

"status":""

}
JSON



echo "[4] Raw Storage Connector..."

cat >"$BASE/storage/raw-connector.json" <<'JSON'
{
"target":

"/var/lib/config-location/raw-storage",

"mode":"append",

"hash":"sha256",

"preserve_original":true

}
JSON



echo "[5] Duplicate Detection..."

cat >"$BASE/dedup/dedup-policy.json" <<'JSON'
{
"algorithm":"sha256",

"duplicate_action":"skip",

"raw_preserved":true

}
JSON



echo "[6] Dev Context..."

python3 <<PY

import json,datetime


data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"phase":23,

"module":"fetch-integration",

"features":[

"fetch-adapter",

"source-manager",

"raw-storage-connector",

"dedup-hook",

"source-health"

],

"mode":"integration-layer"

}


json.dump(
data,
open(
"$REPO/dev-context/fetch-integration/status.json",
"w"
),
indent=2
)

PY


cp "$BASE/adapter/fetch-adapter.json" \
"$REPO/dev-context/fetch-integration/fetch-adapter.json"

cp "$BASE/source/source-schema.json" \
"$REPO/dev-context/fetch-integration/source-schema.json"

cp "$BASE/storage/raw-connector.json" \
"$REPO/dev-context/fetch-integration/raw-connector.json"



echo "[7] GitHub Sync..."

cd "$REPO"

git add dev-context/fetch-integration


git commit \
-m "Phase 23 Fetch Integration $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 23 COMPLETE"
echo "=============================================="

