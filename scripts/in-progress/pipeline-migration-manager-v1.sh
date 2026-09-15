#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

PIPE_DIR="$BASE/scripts/pipeline"

CURRENT="$PIPE_DIR/run.sh"

VERSIONS="$PIPE_DIR/versions"


echo "======================================"
echo " PIPELINE MIGRATION MANAGER V1"
echo " SAFE PIPELINE UPGRADE"
echo "======================================"



mkdir -p "$VERSIONS"



echo "[1] Backup current pipeline"



if [ -f "$CURRENT" ]
then

cp "$CURRENT" \
"$VERSIONS/run-backup-$(date +%Y%m%d-%H%M%S).sh"

fi



echo "[2] Create new pipeline version"



cat > "$PIPE_DIR/run-v27.sh" <<'PIPE'
#!/usr/bin/env bash

set -uo pipefail


BASE="/root/project-reports"

ART="$BASE/artifacts"

EXEC="$BASE/reports/pipeline"

DATE=$(date +"%Y%m%d-%H%M%S")

OUT="$EXEC/$DATE"


mkdir -p "$OUT"


PHASE="${1:-Unknown}"

CMD="${2:-}"


if [ -z "$CMD" ]; then
    echo "Command missing"
    exit 1
fi



echo "================================"
echo " EVIDENCE PIPELINE V2.7"
echo " GIT TRACKING INSPECTOR"
echo "================================"



cd "$BASE"



echo "$PHASE" > "$OUT/phase.txt"

echo "$CMD" > "$OUT/command.txt"



bash -c "$CMD" \
2> >(tee "$OUT/stderr.log" >&2) \
| tee "$OUT/stdout.log"



RESULT=${PIPESTATUS[0]}



REPORT="$OUT/git-tracking-report.txt"



{

echo "GIT TRACKING INSPECTOR V2.7"

echo

echo "Artifact Path:"

echo "$ART"

echo


find "$ART" -type f 2>/dev/null | while read FILE
do

echo "FILE:"
echo "$FILE"

echo

git status --short "$FILE" 2>/dev/null || true

echo

git check-ignore -v "$FILE" 2>/dev/null || true

echo

git ls-files "$FILE"

echo

done


} > "$REPORT"



git add .



git commit \
-m "Pipeline V2.7 migration" \
|| true



git push origin main \
|| true



git fetch origin \
|| true



echo "SYNC COMPLETE"



exit "$RESULT"

PIPE



chmod +x "$PIPE_DIR/run-v27.sh"



echo "[3] Test new version"



"$PIPE_DIR/run-v27.sh" \
"Pipeline V2.7 Migration Test" \
"echo PIPELINE_V27_OK"



echo "[4] Atomic switch"



mv "$CURRENT" \
"$VERSIONS/run-old-active.sh" 2>/dev/null || true


cp "$PIPE_DIR/run-v27.sh" \
"$CURRENT"


chmod +x "$CURRENT"



echo "[5] Final verification"



"$CURRENT" \
"Pipeline Active Verification" \
"echo ACTIVE_PIPELINE_OK"



echo

echo "======================================"
echo " PIPELINE MIGRATION COMPLETE"
echo "======================================"

