#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

PIPE="$BASE/scripts/pipeline/run.sh"


echo "======================================"
echo " PIPELINE V2.8"
echo " TWO PHASE COMMIT CONTROLLER"
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



cd "$BASE"



echo "================================"
echo " EVIDENCE PIPELINE V2.8"
echo " TWO PHASE COMMIT"
echo "================================"



echo "[PHASE 1] EXECUTION"



echo "$PHASE" > "$OUT/phase.txt"

echo "$CMD" > "$OUT/command.txt"



bash -c "$CMD" \
2> >(tee "$OUT/stderr.log" >&2) \
| tee "$OUT/stdout.log"



RESULT=${PIPESTATUS[0]}



if [ "$RESULT" != "0" ]
then

echo "EXECUTION FAILED"

exit "$RESULT"

fi



echo "[PHASE 2] COLLECTION"



find "$ART" \
-type f \
> "$OUT/artifact-list.txt" \
2>/dev/null || true



COUNT=$(wc -l < "$OUT/artifact-list.txt")



echo "Artifact Count: $COUNT"



echo "[PHASE 3] STAGING"



git add .



git diff --cached --name-only \
> "$OUT/staged-files.txt"



STAGED=$(wc -l < "$OUT/staged-files.txt")



if [ "$STAGED" -eq 0 ]
then

echo "NO STAGED FILES"

exit 1

fi



echo "[PHASE 4] COMMIT"



git commit \
-m "Pipeline V2.8 $PHASE $DATE"



echo "[PHASE 5] PUSH"



git push origin main



echo "[PHASE 6] VERIFY"



git fetch origin



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
# Pipeline V2.8


Phase:

$PHASE


Artifacts:

$COUNT


Staged:

$STAGED


Result:

SUCCESS


Generated:

$(date)

SUMMARY



echo

echo "PIPELINE V2.8 COMPLETE"

PIPE


chmod +x "$PIPE"



echo "[TEST]"



mkdir -p "$BASE/artifacts/v28-test"


echo "two-phase-test" \
> "$BASE/artifacts/v28-test/test.txt"



"$PIPE" \
"Pipeline V2.8 Two Phase Test" \
"echo TWO_PHASE_OK"



