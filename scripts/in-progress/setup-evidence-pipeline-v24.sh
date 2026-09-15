#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

PIPE="$BASE/scripts/pipeline/run.sh"

ART="/root/project-artifacts"


echo "======================================"
echo " EVIDENCE PIPELINE V2.4"
echo " ARTIFACT GATEWAY"
echo "======================================"


mkdir -p "$ART"/{
executions,
archives,
logs,
snapshots,
backups,
manifests
}



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



echo "[1] Git Before"


git rev-parse HEAD \
> "$OUT/git-before.txt" 2>/dev/null || true



echo "[2] Execute"



bash -c "$CMD" \
2> >(tee "$OUT/stderr.log" >&2) \
| tee "$OUT/stdout.log"



RESULT=${PIPESTATUS[0]}



echo "[3] Artifact Gateway"



mkdir -p "$ART/manifests"



MANIFEST="$ART/manifests/$DATE.md"



echo "# Artifact Manifest" > "$MANIFEST"

echo >> "$MANIFEST"

echo "Generated:" >> "$MANIFEST"

date >> "$MANIFEST"



echo >> "$MANIFEST"

echo "Files moved:" >> "$MANIFEST"



while read FILE
do

SIZE=$(stat -c%s "$FILE")


if [ "$SIZE" -ge 1048576 ]
then

DEST="$ART/archives/$(basename "$FILE")"

mv "$FILE" "$DEST" 2>/dev/null || true


echo "- $DEST ($SIZE bytes)" >> "$MANIFEST"


fi


done < <(
find "$BASE" \
-type f \
-not -path "*/.git/*"
)



echo "[4] SHA256"


sha256sum "$MANIFEST" \
> "$OUT/manifest.sha256"



echo "[5] Git Metadata"



git add .



git commit \
-m "Pipeline V2.4 $PHASE $DATE" \
|| true



git push origin main \
|| true



echo "[6] Verification"



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
# Pipeline V2.4


Phase:

$PHASE


Status:

$RESULT


Artifact Gateway:

Enabled


Generated:

$(date)

SUMMARY



echo

echo "================================"
echo " PIPELINE V2.4 COMPLETE"
echo "================================"


PIPE



chmod +x "$PIPE"



echo "[TEST]"


"$PIPE" \
"Pipeline V2.4 Gateway Test" \
"echo ARTIFACT_GATEWAY_OK"



