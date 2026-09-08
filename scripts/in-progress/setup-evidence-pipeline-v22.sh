#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

PIPE="$BASE/scripts/pipeline/run.sh"


echo "======================================"
echo " EVIDENCE PIPELINE V2.2"
echo " CENTRALIZED GIT CONTROLLER"
echo "======================================"



mkdir -p "$(dirname "$PIPE")"



cat > "$PIPE" <<'PIPE'
#!/usr/bin/env bash

set -uo pipefail


BASE="/root/project-reports"

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



START=$(date +%s)



echo "$PHASE" > "$OUT/phase.txt"

echo "$CMD" > "$OUT/command.txt"



echo "================================"
echo " EVIDENCE PIPELINE V2.2"
echo " CENTRAL GIT CONTROL"
echo "================================"


echo

echo "PHASE:"
echo "$PHASE"

echo

echo "COMMAND:"
echo "$CMD"

echo



cd "$BASE"



echo "[1] Git state before"


git rev-parse HEAD \
> "$OUT/git-before.txt" 2>/dev/null || true



git status \
> "$OUT/git-status-before.txt" 2>&1 || true



echo "[2] Execute"



bash -c "$CMD" \
2> >(tee "$OUT/stderr.log" >&2) \
| tee "$OUT/stdout.log"



RESULT=${PIPESTATUS[0]}



END=$(date +%s)

DURATION=$((END-START))



echo "$RESULT" > "$OUT/exit-code.txt"



echo "[3] Create summary"



if [ "$RESULT" = "0" ]
then
STATUS="SUCCESS"
else
STATUS="FAILED"
fi



cat > "$OUT/SUMMARY.md" <<SUMMARY
# Pipeline V2.2 Report


Phase:

$PHASE


Command:

$CMD


Status:

$STATUS


Exit:

$RESULT


Duration:

${DURATION}s


Date:

$(date)

SUMMARY



echo "[4] Git Controller"



git add .



git commit \
-m "Pipeline V2.2 $PHASE $DATE" \
|| true



git push origin main



echo "[5] Remote verification"



LOCAL=$(git rev-parse HEAD)

REMOTE=$(git rev-parse origin/main)



{

echo "LOCAL"

echo "$LOCAL"

echo

echo "REMOTE"

echo "$REMOTE"

echo


if [ "$LOCAL" = "$REMOTE" ]
then

echo "REMOTE_SYNC=SUCCESS"

else

echo "REMOTE_SYNC=FAILED"

fi


} > "$OUT/git-verification.txt"



echo "[6] Archive"



tar -czf \
"$OUT.tar.gz" \
-C "$EXEC" \
"$(basename "$OUT")"



echo "[7] Final"



echo "$STATUS" > "$OUT/final-status.txt"



echo

echo "================================"
echo " PIPELINE V2.2 COMPLETE"
echo "================================"

echo "STATUS:"
echo "$STATUS"

echo "REPORT:"
echo "$OUT"


exit "$RESULT"

PIPE



chmod +x "$PIPE"



echo "[TEST]"



"$PIPE" \
"Pipeline V2.2 Central Git Test" \
"echo CENTRAL_GIT_OK && sleep 2 && echo FINISHED"



echo

echo "======================================"
echo " V2.2 INSTALLED"
echo "======================================"

