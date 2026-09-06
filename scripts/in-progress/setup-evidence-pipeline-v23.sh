#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

PIPE="$BASE/scripts/pipeline/run.sh"


echo "======================================"
echo " EVIDENCE PIPELINE V2.3"
echo " ARTIFACT DISCOVERY"
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
echo " EVIDENCE PIPELINE V2.3"
echo " ARTIFACT DISCOVERY"
echo "================================"



cd "$BASE"



echo "[1] Git Before"



git rev-parse HEAD \
> "$OUT/git-before.txt" 2>/dev/null || true



git status --short \
> "$OUT/git-status-before.txt" 2>&1 || true



echo "[2] Execute"



bash -c "$CMD" \
2> >(tee "$OUT/stderr.log" >&2) \
| tee "$OUT/stdout.log"



RESULT=${PIPESTATUS[0]}



END=$(date +%s)

DURATION=$((END-START))



echo "$RESULT" > "$OUT/exit-code.txt"



echo "[3] Git Commit Controller"



git status --short \
> "$OUT/changed-files.txt" 2>&1 || true



git add .



git commit \
-m "Pipeline V2.3 $PHASE $DATE" \
|| true



git push origin main



echo "[4] Remote Discovery"



git fetch origin



LOCAL=$(git rev-parse HEAD)

REMOTE=$(git rev-parse origin/main)



{

echo "LOCAL_HEAD"

echo "$LOCAL"

echo

echo "REMOTE_HEAD"

echo "$REMOTE"

echo


if [ "$LOCAL" = "$REMOTE" ]
then

echo "REMOTE_SYNC=SUCCESS"

else

echo "REMOTE_SYNC=FAILED"

fi


} > "$OUT/remote-verification.txt"



echo "[5] Artifact Discovery"



{

echo "ARTIFACT DISCOVERY"

echo

echo "Changed Files:"

cat "$OUT/changed-files.txt"


echo

echo "Important Files:"


for FILE in \
cache-index.md \
scripts/cache-manager.sh \
scripts/cache-rotate.sh \
storage-manager-v04-report.md
do

if [ -f "$BASE/$FILE" ]
then

echo "$FILE = PRESENT"

else

echo "$FILE = MISSING"

fi

done


} > "$OUT/artifact-verification.txt"



if [ "$RESULT" = "0" ]
then
STATUS="SUCCESS"
else
STATUS="FAILED"
fi



cat > "$OUT/SUMMARY.md" <<SUMMARY
# Evidence Pipeline V2.3 Report


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


Generated:

$(date)

SUMMARY



tar -czf \
"$OUT.tar.gz" \
-C "$EXEC" \
"$(basename "$OUT")"



git add "$OUT" "$OUT.tar.gz"

git commit \
-m "Pipeline V2.3 verification report $DATE" \
|| true


git push origin main \
|| true



echo

echo "================================"
echo " PIPELINE V2.3 COMPLETE"
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
"Pipeline V2.3 Artifact Discovery Test" \
"echo ARTIFACT_DISCOVERY_OK"



echo

echo "======================================"
echo " V2.3 READY"
echo "======================================"

