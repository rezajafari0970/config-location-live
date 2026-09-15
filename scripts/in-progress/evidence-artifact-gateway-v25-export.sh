#!/usr/bin/env bash

set -euo pipefail


SOURCE="/opt/config-manager"

BASE="/root/project-reports"

ART="$BASE/artifacts"



echo "======================================"
echo " ARTIFACT GATEWAY V2.5"
echo " PROJECT EXPORT BRIDGE"
echo "======================================"



if [ ! -d "$SOURCE" ]
then

echo "PROJECT NOT FOUND:"
echo "$SOURCE"

exit 1

fi



echo "[1] Create export structure"



mkdir -p \
"$ART/config-manager" \
"$ART/manifests" \
"$ART/verification" \
"$ART/sha256"



echo "[2] Export project metadata"



find "$SOURCE" \
-type f \
-not -path "*/venv/*" \
-not -path "*/node_modules/*" \
> "$ART/manifests/project-files.txt"



echo "[3] Export important project files"



for FILE in \
docs \
backend \
frontend \
workers \
tests \
installer
do

if [ -e "$SOURCE/$FILE" ]
then

cp -r \
"$SOURCE/$FILE" \
"$ART/config-manager/"


fi

done



echo "[4] Generate manifest"



{

echo "# Config Manager Export Manifest"

echo

echo "Source:"

echo "$SOURCE"

echo

echo "Generated:"

date

echo

echo "Files:"

cat "$ART/manifests/project-files.txt"


} > "$ART/manifests/export-manifest.md"



echo "[5] SHA256"



cd "$ART"


find config-manager \
-type f \
-exec sha256sum {} \; \
> sha256/config-manager.sha256



echo "[6] Verification report"



cat > "$ART/verification/export-report.md" <<REPORT
# Export Bridge V2.5


Status:

READY


Source:

$SOURCE


Files:

$(wc -l < "$ART/manifests/project-files.txt")


Generated:

$(date)

REPORT



echo

echo "======================================"
echo " EXPORT BRIDGE COMPLETE"
echo "======================================"

