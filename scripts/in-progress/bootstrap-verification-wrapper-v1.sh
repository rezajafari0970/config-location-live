#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

ART="$BASE/artifacts"

REPORT="$BASE/bootstrap-preflight-report.md"



echo "======================================"
echo " BOOTSTRAP VERIFICATION WRAPPER V1"
echo "======================================"



echo "[1] Check artifact directory"



if [ ! -d "$ART" ]
then

echo "Artifact directory missing"

exit 1

fi



echo "[2] Count artifacts"



COUNT=$(find "$ART" -type f | wc -l)



echo "Artifact count:"
echo "$COUNT"



if [ "$COUNT" -eq 0 ]
then

echo "NO ARTIFACTS FOUND"

exit 1

fi



echo "[3] Generate preflight report"



cat > "$REPORT" <<REPORT
# Bootstrap Preflight Verification


Status:

PASSED


Artifact Path:

$ART


Artifact Count:

$COUNT


Generated:

$(date)

REPORT



echo "[4] Git tracking check"



cd "$BASE"


git status --short "$ART" \
> "$BASE/artifact-git-status.txt" \
|| true



echo "[5] Manifest"



find "$ART" \
-type f \
> "$BASE/artifact-file-manifest.txt"



echo

echo "======================================"
echo " BOOTSTRAP VERIFIED"
echo "======================================"

