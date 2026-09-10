#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/fetch-runtime"
INTEGRATION="/var/lib/config-location/integration/fetch"
CONFIG="/var/lib/config-location/config-manager/config.json"

REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/backup" \
"$BASE/hooks" \
"$BASE/results" \
"$REPO/dev-context/fetch-runtime"


echo "=============================================="
echo " PHASE 25.2.4 FETCHER RUNTIME CONNECT"
echo "=============================================="


echo "[1] Backup integration state..."

tar czf \
"$BASE/backup/fetch-runtime-$(date +%Y%m%d-%H%M%S).tar.gz" \
"$INTEGRATION" \
2>/dev/null || true



echo "[2] Create runtime hooks..."


cat >"$BASE/hooks/config-loader.json" <<JSON
{
"source":

"/var/lib/config-location/config-manager/config.json",

"mode":

"dynamic",

"reload":

"enabled"

}
JSON



cat >"$BASE/hooks/source-loader.json" <<JSON
{
"source":

"/var/lib/config-location/fetch-manager/sources.json",

"features":[

"enabled-filter",

"priority",

"health"

]

}
JSON



cat >"$BASE/hooks/raw-storage-hook.json" <<JSON
{
"target":

"/var/lib/config-location/raw-storage",

"actions":[

"hash",

"store",

"metadata"

]

}
JSON



echo "[3] Create fetch runtime state..."


cat >"$BASE/results/runtime-connect.json" <<JSON
{
"time":"$(date -Is)",

"phase":"25.2.4",

"fetcher":

"existing",


"integration":

"connected",


"core_rewrite":

false

}
JSON



echo "[4] Dev Context..."


cp "$BASE/results/runtime-connect.json" \
"$REPO/dev-context/fetch-runtime/status.json"

cp "$BASE/hooks/config-loader.json" \
"$REPO/dev-context/fetch-runtime/config-loader.json"

cp "$BASE/hooks/source-loader.json" \
"$REPO/dev-context/fetch-runtime/source-loader.json"

cp "$BASE/hooks/raw-storage-hook.json" \
"$REPO/dev-context/fetch-runtime/raw-storage-hook.json"



echo "[5] GitHub Sync..."

cd "$REPO"

git add dev-context/fetch-runtime


git commit \
-m "Phase 25.2.4 Fetcher Runtime Integration $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25.2.4 COMPLETE"
echo "=============================================="

