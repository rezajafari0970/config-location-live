#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

PIPE="$BASE/scripts/pipeline/run.sh"


echo "======================================"
echo " EVIDENCE PIPELINE V2.6"
echo " ARTIFACT PRE-COMMIT VALIDATOR"
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
echo " EVIDENCE PIPELINE V2.6"
echo " ARTIFACT PRE-COMMIT VALIDATOR"
echo "================================"



cd "$BASE"



echo "$PHASE" > "$OUT/phase.txt"

echo "$CMD" > "$OUT/command.txt"



echo "[EXECUTE]"



bash -c "$CMD" \
2> >(tee "$OUT/stderr.log" >&2) \
| tee "$OUT/stdout.log"



RESULT=${PIPESTATUS[0]}



echo "[ARTIFACT VALIDATION]"



GATE="$OUT/artifact-gate.txt"



{

echo "ARTIFACT GATE V2.6"

echo

echo "Artifact Path:"

echo "$ART"

echo


if [ -d "$ART" ]
then

echo "ARTIFACT_DIR=OK"

else

echo "ARTIFACT_DIR=MISSING"

fi



echo

echo "Tracked Files:"

git status --short "$ART" 2>/dev/null || true



echo

echo "Artifact Count:"

find "$ART" -type f 2>/dev/null | wc -l



} > "$GATE"



COUNT=$(find "$ART" -type f 2>/dev/null | wc -l)



if [ "$COUNT" -eq 0 ]
then

echo "ARTIFACT_GATE=FAILED" >> "$GATE"

echo "Commit blocked"

exit 1

else

echo "ARTIFACT_GATE=PASSED" >> "$GATE"

fi



echo "[GIT CONTROLLER]"



git add .



git commit \
-m "Pipeline V2.6 $PHASE $DATE" \
|| true



git push origin main \
|| true



echo "[REMOTE VERIFY]"



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
# Evidence Pipeline V2.6


Phase:

$PHASE


Result:

$RESULT


Artifact Gate:

PASSED


Generated:

$(date)

SUMMARY



echo

echo "================================"
echo " PIPELINE V2.6 COMPLETE"
echo "================================"


exit "$RESULT"

PIPE



chmod +x "$PIPE"



echo "[TEST]"



mkdir -p "$BASE/artifacts/test"

echo "artifact-test" \
> "$BASE/artifacts/test/test.txt"



"$PIPE" \
"Pipeline V2.6 Validator Test" \
"echo ARTIFACT_VALIDATOR_OK && sleep 2 && echo FINISHED"



