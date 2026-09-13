#!/usr/bin/env bash

set -euo pipefail


SOURCE="/opt/config-manager"

BASE="/root/project-reports"

ART="$BASE/artifacts/source-snapshots"


echo "======================================"
echo " CONFIG MANAGER"
echo " PHASE 1.1 SOURCE SNAPSHOT FIX"
echo "======================================"

date


if [ ! -d "$SOURCE" ]
then
    echo "SOURCE NOT FOUND"
    exit 1
fi



echo "[1] Create artifact structure"



mkdir -p \
"$ART/config-manager" \
"$BASE/artifacts/manifests" \
"$BASE/artifacts/hashes" \
"$BASE/artifacts/verification"



echo "[2] Export source snapshot"



rsync -a \
--exclude venv \
--exclude node_modules \
--exclude __pycache__ \
--exclude "*.pyc" \
--exclude storage/logs \
"$SOURCE/" \
"$ART/config-manager/"



echo "[3] Source manifest"



find "$ART/config-manager" \
-type f \
| sort \
> "$BASE/artifacts/manifests/source-manifest.txt"



COUNT=$(wc -l < "$BASE/artifacts/manifests/source-manifest.txt")



echo "Files: $COUNT"



echo "[4] SHA256"



cd "$ART"


find config-manager \
-type f \
-exec sha256sum {} \; \
> "$BASE/artifacts/hashes/source.sha256"



echo "[5] Verification"



cat > "$BASE/artifacts/verification/source-snapshot-verification.md" <<VERIFY
# Source Snapshot Verification


Phase:

1.1


Status:

SUCCESS


Source:

$SOURCE


Export:

$ART/config-manager


Files:

$COUNT


Generated:

$(date)

VERIFY



echo "[6] Snapshot complete"



echo

echo "======================================"
echo " SOURCE SNAPSHOT READY"
echo " Files: $COUNT"
echo "======================================"

