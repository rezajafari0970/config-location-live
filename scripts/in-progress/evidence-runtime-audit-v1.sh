#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

REPORT="$BASE/runtime-audit"


PIPE="$BASE/reports/pipeline"



echo "======================================"
echo " EVIDENCE RUNTIME AUDIT V1"
echo " PIPELINE EXECUTION ANALYSIS"
echo "======================================"



mkdir -p "$REPORT"



echo "[1] Pipeline runs"



find "$PIPE" \
-maxdepth 1 \
-type d \
-name "20*" \
| sort \
> "$REPORT/pipeline-runs.txt"



LATEST=$(tail -n 1 "$REPORT/pipeline-runs.txt" || true)



echo "$LATEST" \
> "$REPORT/latest-run.txt"



echo "[2] Latest run inspection"



if [ -n "$LATEST" ] && [ -d "$LATEST" ]
then


ls -la "$LATEST" \
> "$REPORT/latest-files.txt"


cp "$LATEST/stdout.log" \
"$REPORT/stdout.log" \
2>/dev/null || true


cp "$LATEST/stderr.log" \
"$REPORT/stderr.log" \
2>/dev/null || true


cp "$LATEST/verification.txt" \
"$REPORT/verification.txt" \
2>/dev/null || true


cp "$LATEST/SUMMARY.md" \
"$REPORT/SUMMARY.md" \
2>/dev/null || true


fi



echo "[3] Artifact state"



{

echo "ARTIFACT DIRECTORY"

echo

find "$BASE/artifacts" \
-type f \
2>/dev/null \
| wc -l


echo

find "$BASE/artifacts" \
-type f \
2>/dev/null

} > "$REPORT/artifact-state.txt"



echo "[4] Git state"



cd "$BASE"



{

echo "GIT STATUS"

git status --short


echo

echo "TRACKED ARTIFACTS"

git ls-files artifacts/


echo

echo "REMOTE"

git remote -v


} > "$REPORT/git-state.txt"



echo "[5] Final audit"



cat > "$REPORT/FINAL-AUDIT.md" <<AUDIT
# Evidence Runtime Audit V1


Generated:

$(date)


Latest Pipeline Run:

$LATEST


Artifact Count:

$(find "$BASE/artifacts" -type f 2>/dev/null | wc -l)


Audit:

COMPLETED

AUDIT



echo

echo "======================================"
echo " RUNTIME AUDIT COMPLETE"
echo "======================================"

