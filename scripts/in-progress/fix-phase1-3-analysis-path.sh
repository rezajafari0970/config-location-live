#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEV="/var/lib/config-location/dev-assistant-v3"

echo "=============================================="
echo " FIX PHASE 1.3 ANALYSIS INPUT"
echo "=============================================="


mkdir -p "$DEV/analysis"


LATEST=$(ls -1t "$DEV/analysis/"*.json 2>/dev/null | head -1 || true)


if [ -z "$LATEST" ]; then
    echo "ERROR: No analysis json found"
    echo "Available files:"
    find "$DEV" -path "*analysis*" -type f 2>/dev/null || true
    exit 1
fi


echo "Found:"
echo "$LATEST"


cp "$LATEST" \
"$DEV/analysis/core-analysis-latest.json"


echo
echo "Created:"
echo "$DEV/analysis/core-analysis-latest.json"


echo
echo "Now rerun Phase 1.3..."

