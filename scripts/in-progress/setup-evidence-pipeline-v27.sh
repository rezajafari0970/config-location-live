#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

PIPE="$BASE/scripts/pipeline/run.sh"


echo "======================================"
echo " EVIDENCE PIPELINE V2.7"
echo " GIT TRACKING INSPECTOR"
echo "======================================"



mkdir -p "$(dirname "$PIPE")"



cat > "$PIPE" <<'PIPE'
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



echo "[EXECUTE]"



bash -c "$CMD" \
2> >(tee "$OUT/stderr.log" >&2) \
| tee "$OUT/stdout.log"



RESULT=${PIPESTATUS[0]}



echo "[GIT INSPECTION]"



REPORT="$OUT/git-tracking-report.txt"



{

echo "GIT TRACKING INSPECTOR V2.7"

echo

echo "Artifact Path:"

echo "$ART"

echo


echo "FILES:"

find "$ART" -type f 2>/dev/null | while read FILE
do

echo "---------------------"

echo "FILE:"
echo "$FILE"


echo

echo "EXISTS:"
test -f "$FILE" && echo YES || echo NO


echo

echo "GIT STATUS:"

git status --short "$FILE" 2>/dev/null || true


echo

echo "IGNORE CHECK:"

git check-ignore -v "$FILE" 2>/dev/null || echo "NOT_IGNORED"


echo

echo "TRACKED:"

git ls-files "$FILE"


done



echo

echo "STAGED FILES:"

git diff --cached --name-only



} > "$REPORT"



echo "[GIT ADD]"



git add "$ART" || true



echo "[AFTER ADD]"



git diff --cached --name-only \
> "$OUT/staged-files.txt"



echo "[COMMIT]"



git commit \
-m "Pipeline V2.7 $PHASE $DATE" \
|| true



git push origin main \
|| true



git fetch origin \
|| true



LOCAL=$(git rev-parse HEAD)

REMOTE=$(git rev-parse origin/main)



{

echo "LOCAL=$LOCAL"

echo "REMOTE=$REMOTE"


if [ "$LOCAL" = "$REMOTE" ]
then

echo "SYNC=SUCCESS"

else

echo "SYNC=FAILED"

fi


} > "$OUT/verification.txt"



cat > "$OUT/SUMMARY.md" <<SUMMARY
# Evidence Pipeline V2.7


Phase:

$PHASE


Result:

$RESULT


Git Tracking Inspection:

DONE


Generated:

$(date)

SUMMARY



echo

echo "================================"
echo " PIPELINE V2.7 COMPLETE"
echo "================================"


exit "$RESULT"

PIPE



chmod +x "$PIPE"



echo "[TEST]"



mkdir -p "$BASE/artifacts/tracking-test"


echo "tracking-test" \
> "$BASE/artifacts/tracking-test/test.txt"



"$PIPE" \
"Pipeline V2.7 Git Tracking Test" \
"echo GIT_TRACKING_OK && sleep 2 && echo FINISHED"

