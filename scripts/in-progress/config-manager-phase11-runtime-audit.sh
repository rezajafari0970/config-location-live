#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

REPORT="$BASE/phase11-audit"

PIPE="$BASE/reports/pipeline"


echo "======================================"
echo " CONFIG MANAGER"
echo " PHASE 1.1 RUNTIME EVIDENCE AUDIT"
echo "======================================"



mkdir -p "$REPORT"



echo "[1] Pipeline Runs"



find "$PIPE" \
-maxdepth 1 \
-type d \
-name "20*" \
| sort \
> "$REPORT/pipeline-list.txt"



LATEST=$(tail -n 1 "$REPORT/pipeline-list.txt" || true)



echo "$LATEST" \
> "$REPORT/latest-run.txt"



echo "[2] Collect Latest Evidence"



if [ -n "$LATEST" ] && [ -d "$LATEST" ]
then


cp "$LATEST/SUMMARY.md" \
"$REPORT/summary.txt" \
2>/dev/null || true


cp "$LATEST/staged-files.txt" \
"$REPORT/staged.txt" \
2>/dev/null || true


cp "$LATEST/verification.txt" \
"$REPORT/verification.txt" \
2>/dev/null || true


cp "$LATEST/stdout.log" \
"$REPORT/stdout.log" \
2>/dev/null || true


cp "$LATEST/stderr.log" \
"$REPORT/stderr.log" \
2>/dev/null || true


fi



echo "[3] Git Status"



cd "$BASE"


git status \
> "$REPORT/git-status.txt" \
2>&1 || true



git ls-files \
> "$REPORT/tracked-files.txt" \
2>&1 || true



echo "[4] Project Files Check"



{

echo "PROJECT FILE CHECK"

echo

for FILE in \
/opt/config-manager/backend/app/main.py \
/opt/config-manager/workers/fetch_worker.py \
/opt/config-manager/systemd/config-manager.service \
/opt/config-manager/storage/reports/health-test.json

do

echo "FILE:"
echo "$FILE"

if [ -f "$FILE" ]
then
echo "EXISTS=YES"
else
echo "EXISTS=NO"
fi

echo

done

} > "$REPORT/project-check.txt"



echo "[5] Final Report"



cat > "$REPORT/FINAL-REPORT.md" <<REPORT
# Phase 1.1 Runtime Evidence Audit


Generated:

$(date)


Latest Pipeline Run:

$LATEST


Project:

/opt/config-manager


Audit:

COMPLETED


REPORT



echo

echo "======================================"
echo " PHASE 1.1 AUDIT COMPLETE"
echo "======================================"

