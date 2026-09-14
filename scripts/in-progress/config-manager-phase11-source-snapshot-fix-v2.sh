#!/usr/bin/env bash

set -euo pipefail


SOURCE="/opt/config-manager"

BASE="/root/project-reports"

ART="$BASE/artifacts"


echo "======================================"
echo " PHASE 1.1 SOURCE SNAPSHOT FIX V2"
echo "======================================"

date


echo "[1] Prepare artifact folders"


mkdir -p \
"$ART/source-snapshots/config-manager" \
"$ART/manifests" \
"$ART/hashes" \
"$ART/verification"



echo "[2] Export source"



rsync -a \
--delete \
--exclude venv \
--exclude node_modules \
--exclude __pycache__ \
--exclude "*.pyc" \
--exclude "storage/logs/*" \
"$SOURCE/" \
"$ART/source-snapshots/config-manager/"



COUNT=$(find "$ART/source-snapshots/config-manager" -type f | wc -l)


if [ "$COUNT" -eq 0 ]
then
    echo "NO SOURCE FILES EXPORTED"
    exit 1
fi



echo "[3] Manifest"



find "$ART/source-snapshots/config-manager" \
-type f \
| sort \
> "$ART/manifests/source-manifest.txt"



echo "[4] Hash"



cd "$ART/source-snapshots"


sha256sum \
$(find config-manager -type f) \
> "$ART/hashes/source.sha256"



echo "[5] Verification"



cat > "$ART/verification/source-snapshot-verification.md" <<VERIFY
# Source Snapshot Verification

Phase:

1.1

Status:

SUCCESS

Source:

$SOURCE

Files:

$COUNT

Generated:

$(date)

VERIFY



echo "[6] Pre Commit Check"



echo "SOURCE_FILES=$COUNT"


find "$ART/source-snapshots/config-manager" \
-type f \
| head -20



echo

echo "======================================"
echo " SNAPSHOT READY"
echo " FILES: $COUNT"
echo "======================================"

