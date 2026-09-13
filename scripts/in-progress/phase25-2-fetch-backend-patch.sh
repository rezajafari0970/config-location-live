#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CORE="/opt/config-location"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

BASE="$DEV/fetch-backend-patch"

mkdir -p \
"$BASE/backup" \
"$BASE/adapter" \
"$BASE/results" \
"$REPO/dev-context/fetch-backend"


echo "=============================================="
echo " PHASE 25.2 FETCH BACKEND INTEGRATION"
echo "=============================================="


echo "[1] Backup Core..."

tar czf \
"$BASE/backup/core-fetch-before-$(date +%Y%m%d-%H%M%S).tar.gz" \
"$CORE" \
2>/dev/null || true



echo "[2] Create Config Adapter..."

cat >"$BASE/adapter/config-manager-adapter.json" <<JSON
{
"version":1,

"source":

"/var/lib/config-location/config-manager/config.json",

"bindings":[

"timeout",

"retry",

"worker_mode",

"interval"

]

}
JSON



echo "[3] Create Source Adapter..."

cat >"$BASE/adapter/source-manager-adapter.json" <<JSON
{
"version":1,

"source":

"/var/lib/config-location/fetch-manager/sources.json",

"fields":[

"enabled",

"priority",

"status"

]

}
JSON



echo "[4] Create Raw Storage Hook..."

cat >"$BASE/adapter/raw-storage-hook.json" <<JSON
{
"version":1,

"target":

"/var/lib/config-location/raw-storage",

"actions":[

"sha256",

"save_raw",

"metadata"

]

}
JSON



echo "[5] Create Fetch Result Model..."

cat >"$BASE/results/fetch-result-schema.json" <<JSON
{
"source":"",

"time":"",

"status":"",

"configs_found":0,

"errors":[]

}
JSON



echo "[6] Create Integration State..."

cat >"$BASE/results/integration-state.json" <<JSON
{
"phase":"25.2",

"fetcher":

"existing",


"adapter":

"enabled",


"core_rewrite":

false

}
JSON



echo "[7] Dev Context..."

cp "$BASE/adapter/"*.json \
"$REPO/dev-context/fetch-backend/"


cp "$BASE/results/"*.json \
"$REPO/dev-context/fetch-backend/"


echo "[8] GitHub Sync..."

cd "$REPO"

git add dev-context/fetch-backend


git commit \
-m "Phase 25.2 Fetch Backend Integration $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25.2 COMPLETE"
echo "=============================================="

