#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/raw-storage"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/configs" \
"$BASE/history" \
"$REPO/dev-context/raw-storage"


echo "=============================================="
echo " PHASE 6 RAW STORAGE FOUNDATION"
echo "=============================================="


echo "[1] Storage Structure"

cat >"$BASE/storage-policy.json" <<JSON
{
"version":1,

"raw_preserve":true,

"hash_algorithm":"sha256",

"duplicate_detection":true,

"versioning":true,

"retention":"from-config-manager"

}
JSON


echo "[2] Create Index"

cat >"$BASE/index.json" <<JSON
{
"version":1,
"configs":[],
"updated":"$(date -Is)"
}
JSON


echo "[3] Create Raw Config Schema"

cat >"$BASE/config-schema.json" <<JSON
{
"id":"",
"raw":"",
"hash":"",
"source":"",
"first_seen":"",
"last_seen":"",
"versions":[],
"metadata":{}
}
JSON


echo "[4] Create Dev Context"


python3 <<PY

import json,datetime


data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"module":"raw-storage",

"features":[

"raw-preservation",

"sha256",

"versioning",

"duplicate-detection",

"source-tracking"

]

}


json.dump(
data,
open(
"$REPO/dev-context/raw-storage/storage-status.json",
"w"
),
indent=2
)


PY


cp "$BASE/storage-policy.json" \
"$REPO/dev-context/raw-storage/storage-policy.json"


cp "$BASE/config-schema.json" \
"$REPO/dev-context/raw-storage/config-schema.json"



echo "[5] GitHub Sync..."

cd "$REPO"

git add dev-context/raw-storage


git commit \
-m "Phase 6 Raw Storage Foundation $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 6 COMPLETE"
echo "=============================================="

