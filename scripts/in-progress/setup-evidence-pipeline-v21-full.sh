#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"
PIPE="$BASE/scripts/pipeline/run.sh"


echo "======================================"
echo " EVIDENCE PIPELINE V2.1 FULL REPLACE"
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



echo "$PHASE" > "$OUT/phase.txt"

echo "$CMD" > "$OUT/command.txt"



START=$(date +%s)



echo "================================"
echo " EVIDENCE PIPELINE V2.1"
echo " SELF VERIFIED"
echo "================================"

echo

echo "PHASE:"
echo "$PHASE"

echo

echo "COMMAND:"
echo "$CMD"

echo



cd "$BASE"



git rev-parse HEAD > "$OUT/git-before.txt" 2>/dev/null || true

git status > "$OUT/git-status-before.txt" 2>&1 || true



find /opt/config-manager \
-type f \
-exec sha256sum {} \; \
> "$OUT/sha256-before.txt" 2>/dev/null || true



echo "===== LIVE OUTPUT ====="



bash -c "$CMD" \
2> >(tee "$OUT/stderr.log" >&2) \
| tee "$OUT/stdout.log"



RESULT=${PIPESTATUS[0]}



END=$(date +%s)

DURATION=$((END-START))



echo "$RESULT" > "$OUT/exit-code.txt"



date -Is > "$OUT/end-time.txt"



git rev-parse HEAD > "$OUT/git-after.txt" 2>/dev/null || true

git status > "$OUT/git-status-after.txt" 2>&1 || true



find /opt/config-manager \
-type f \
-exec sha256sum {} \; \
> "$OUT/sha256-after.txt" 2>/dev/null || true



if [ "$RESULT" = "0" ]
then
STATUS="SUCCESS"
else
STATUS="FAILED"
fi



cat > "$OUT/SUMMARY.md" <<SUMMARY
# Evidence Pipeline V2.1 Report


Phase:

$PHASE


Command:

$CMD


Status:

$STATUS


Exit Code:

$RESULT


Duration:

${DURATION}s


Time:

$(date)

SUMMARY



tar -czf \
"$OUT.tar.gz" \
-C "$EXEC" \
"$(basename "$OUT")"



INDEX="$EXEC/INDEX.md"


if [ ! -f "$INDEX" ]
then

echo "|Date|Phase|Status|" > "$INDEX"
echo "|---|---|---|" >> "$INDEX"

fi


echo "|$DATE|$PHASE|$STATUS|" >> "$INDEX"



echo "[SELF VERIFICATION]"



VERIFY="$OUT/verification.txt"



{

echo "EVIDENCE PIPELINE V2.1"

echo

echo "CHECK SUMMARY"

if [ -f "$OUT/SUMMARY.md" ]; then
echo "SUMMARY=OK"
else
echo "SUMMARY=FAILED"
fi


echo

echo "CHECK ARCHIVE"

if [ -f "$OUT.tar.gz" ]; then
echo "ARCHIVE=OK"
else
echo "ARCHIVE=FAILED"
fi


echo

echo "CHECK GIT"

git rev-parse HEAD || echo "GIT_FAILED"


echo

echo "CHECK STATUS"

git status --short

} > "$VERIFY"



if grep -q "FAILED" "$VERIFY"
then
VERIFY_STATUS="FAILED"
else
VERIFY_STATUS="SUCCESS"
fi



echo "VERIFICATION=$VERIFY_STATUS" >> "$VERIFY"



echo "$VERIFY_STATUS" > "$OUT/verification-status.txt"



cd "$BASE"



git add .


git commit \
-m "Evidence Pipeline V2.1 Full Replace $DATE" \
|| true



git push origin main \
|| true



echo

echo "================================"
echo " PIPELINE V2.1 COMPLETE"
echo "================================"

echo "STATUS:"
echo "$STATUS"

echo

echo "VERIFY:"
echo "$VERIFY_STATUS"

echo

echo "REPORT:"
echo "$OUT"



exit "$RESULT"

PIPE



chmod +x "$PIPE"



echo "[1] Pipeline replaced"



echo "[2] Running V2.1 self test"



"$PIPE" \
"Pipeline V2.1 Self Test" \
"echo V21_START && sleep 2 && echo V21_FINISHED"



echo

echo "======================================"
echo " V2.1 FULL REPLACE DONE"
echo "======================================"

