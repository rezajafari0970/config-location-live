#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

PIPE="$BASE/scripts/pipeline/run.sh"

ART="/root/project-artifacts"


echo "======================================"
echo " EVIDENCE PIPELINE V2.4 FIXED"
echo " ARTIFACT GATEWAY"
echo "======================================"



echo "[1] Create artifact storage"



mkdir -p \
"$ART/executions" \
"$ART/archives" \
"$ART/logs" \
"$ART/snapshots" \
"$ART/backups" \
"$ART/manifests"



echo "[2] Replace pipeline"



cat > "$PIPE" <<'PIPE'
#!/usr/bin/env bash

set -uo pipefail


BASE="/root/project-reports"

ART="/root/project-artifacts"

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
echo " EVIDENCE PIPELINE V2.4"
echo " ARTIFACT GATEWAY"
echo "================================"



cd "$BASE"



echo "$PHASE" > "$OUT/phase.txt"

echo "$CMD" > "$OUT/command.txt"



echo "[EXECUTE]"



bash -c "$CMD" \
2> >(tee "$OUT/stderr.log" >&2) \
| tee "$OUT/stdout.log"



RESULT=${PIPESTATUS[0]}



echo "[ARTIFACT GATEWAY]"



MANIFEST="$ART/manifests/$DATE.md"



{

echo "# Artifact Manifest"

echo

echo "Generated:"

date

echo

echo "Files:"

find "$BASE" \
-type f \
-not -path "*/.git/*"

} > "$MANIFEST"



sha256sum "$MANIFEST" \
> "$OUT/manifest.sha256"



echo "[GIT CONTROLLER]"



git add .



git commit \
-m "Pipeline V2.4 $PHASE $DATE" \
|| true



git push origin main \
|| true



echo "[VERIFY]"



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
# Evidence Pipeline V2.4


Phase:

$PHASE


Result:

$RESULT


Generated:

$(date)

SUMMARY



echo

echo "================================"
echo " PIPELINE V2.4 COMPLETE"
echo "================================"

echo "$OUT"


exit "$RESULT"

PIPE



chmod +x "$PIPE"



echo "[3] TEST"



"$PIPE" \
"Pipeline V2.4 Fixed Test" \
"echo ARTIFACT_GATEWAY_OK && sleep 2 && echo FINISHED"



echo

echo "======================================"
echo " V2.4 FIXED READY"
echo "======================================"

