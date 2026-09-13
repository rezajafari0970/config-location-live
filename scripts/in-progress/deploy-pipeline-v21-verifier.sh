#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

PIPE="$BASE/scripts/pipeline/run.sh"

REPORT="$BASE/pipeline-v21-deployment-report.txt"


echo "======================================"
echo " PIPELINE V2.1 DEPLOYMENT VERIFIER "
echo "======================================"



{
echo "EVIDENCE PIPELINE V2.1 DEPLOYMENT REPORT"
echo
date
echo

} > "$REPORT"



echo "[1] Checking local pipeline"



if [ ! -f "$PIPE" ]; then

echo "LOCAL FILE: FAILED" | tee -a "$REPORT"

exit 1

fi



echo "LOCAL FILE: OK" | tee -a "$REPORT"



echo "[2] Checking V2.1 markers"



if grep -q "VERIFICATION" "$PIPE" && \
   grep -q "verification.txt" "$PIPE"
then

echo "V2.1 MARKERS: OK" | tee -a "$REPORT"

else

echo "V2.1 MARKERS: FAILED" | tee -a "$REPORT"

fi



echo "[3] SHA256"



sha256sum "$PIPE" | tee -a "$REPORT"



echo "[4] Git status"



cd "$BASE"

git status | tee -a "$REPORT"



echo "[5] Commit current state"



git add .


git commit \
-m "Pipeline V2.1 deployment verification $(date +%Y%m%d-%H%M%S)" \
|| true



echo "[6] Push"



git push origin main | tee -a "$REPORT"



echo "[7] Verify remote commit"



REMOTE=$(git rev-parse origin/main)

LOCAL=$(git rev-parse HEAD)



echo "LOCAL:"
echo "$LOCAL" | tee -a "$REPORT"

echo "REMOTE:"
echo "$REMOTE" | tee -a "$REPORT"



if [ "$LOCAL" = "$REMOTE" ]
then

echo "REMOTE SYNC: OK" | tee -a "$REPORT"

else

echo "REMOTE SYNC: FAILED" | tee -a "$REPORT"

fi



echo "[8] Test execution"



"$PIPE" \
"V2.1 Verification Test" \
"echo PIPELINE_V21_OK"



echo

echo "======================================"
echo " DEPLOYMENT VERIFICATION COMPLETE "
echo "======================================"



echo "REPORT:"
echo "$REPORT"

