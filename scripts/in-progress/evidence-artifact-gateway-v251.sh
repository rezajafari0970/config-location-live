#!/usr/bin/env bash

set -euo pipefail


SOURCE="/opt/config-manager"

BASE="/root/project-reports"

ART="$BASE/artifacts"



echo "======================================"
echo " ARTIFACT GATEWAY V2.5.1"
echo " VERIFIED EXPORT GATE"
echo "======================================"



echo "[1] Validate source"



if [ ! -d "$SOURCE" ]
then

echo "SOURCE MISSING"
exit 1

fi



echo "[2] Create artifact structure"



mkdir -p \
"$ART/exports/config-manager" \
"$ART/manifests" \
"$ART/verification" \
"$ART/hashes"



echo "[3] Export project"



rsync -a \
--exclude venv \
--exclude node_modules \
"$SOURCE/" \
"$ART/exports/config-manager/"



echo "[4] Verify export"



EXPORTED=$(find "$ART/exports/config-manager" -type f | wc -l)



if [ "$EXPORTED" -eq 0 ]
then

echo "EXPORT EMPTY"

exit 1

fi



echo "[5] Manifest"



find "$ART/exports/config-manager" \
-type f \
> "$ART/manifests/project-export-manifest.txt"



cat > "$ART/manifests/export-summary.md" <<REPORT
# Verified Export Summary


Source:

$SOURCE


Export:

$ART/exports/config-manager


Files:

$EXPORTED


Generated:

$(date)

REPORT



echo "[6] SHA256"



cd "$ART/exports"


sha256sum \
$(find config-manager -type f) \
> "$ART/hashes/config-manager.sha256"



echo "[7] Verification"



cat > "$ART/verification/export-verification.md" <<VERIFY
# Export Verification


Status:

SUCCESS


Files:

$EXPORTED


Source:

$SOURCE


Time:

$(date)

VERIFY



echo

echo "======================================"
echo " VERIFIED EXPORT COMPLETE"
echo "======================================"

