#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

ART="$BASE/artifacts"



echo "======================================"
echo " EVIDENCE ARTIFACT COLLECTOR V1"
echo "======================================"



echo "[1] Create artifact structure"



mkdir -p "$ART"/{
storage-manager,
environment,
manifests
}



echo "[2] Collect storage manager files"



if [ -f "$BASE/cache-index.md" ]
then

cp "$BASE/cache-index.md" \
"$ART/storage-manager/"

fi



if [ -f "$BASE/scripts/cache-manager.sh" ]
then

cp "$BASE/scripts/cache-manager.sh" \
"$ART/storage-manager/"

fi



if [ -f "$BASE/scripts/cache-rotate.sh" ]
then

cp "$BASE/scripts/cache-rotate.sh" \
"$ART/storage-manager/"

fi



if [ -f "$BASE/storage-manager-v04-report.md" ]
then

cp "$BASE/storage-manager-v04-report.md" \
"$ART/storage-manager/report.md"

fi



echo "[3] Collect environment artifacts"



if [ -d "/opt/config-manager/docs/environment" ]
then

cp -r \
/opt/config-manager/docs/environment/* \
"$ART/environment/" \
2>/dev/null || true

fi



echo "[4] Generate manifest"



find "$ART" \
-type f \
> "$ART/manifests/files.txt"



echo "[5] Generate SHA256"



cd "$ART"

sha256sum \
$(find . -type f) \
> "$ART/manifests/sha256.txt" \
2>/dev/null || true



echo "[6] Create collector report"



cat > "$ART/manifests/COLLECTOR-REPORT.md" <<REPORT
# Artifact Collector V1


Status:

READY


Files:

$(find "$ART" -type f | wc -l)


Generated:

$(date)

REPORT



echo

echo "======================================"
echo " ARTIFACT COLLECTION COMPLETE"
echo "======================================"

