#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

PIPE="$BASE/scripts/pipeline"


mkdir -p "$PIPE"



cat > "$PIPE/run.sh" <<'RUNNER'
#!/usr/bin/env bash

set -uo pipefail


BASE="/root/project-reports"

EXEC="$BASE/reports/pipeline"

DATE=$(date +"%Y%m%d-%H%M%S")


mkdir -p "$EXEC"


PHASE="${1:-Unknown}"

CMD="${2:-}"


if [ -z "$CMD" ]; then
    echo "Command missing"
    exit 1
fi


OUT="$EXEC/$DATE"

mkdir -p "$OUT"



echo "$PHASE" > "$OUT/phase.txt"

echo "$CMD" > "$OUT/command.txt"



START=$(date +%s)


echo "================================"
echo " EVIDENCE PIPELINE V2"
echo "================================"

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
# Execution Report


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



tar -czf "$OUT.tar.gz" \
-C "$EXEC" \
"$(basename "$OUT")"



mkdir -p "$EXEC"



INDEX="$EXEC/INDEX.md"


if [ ! -f "$INDEX" ]
then

echo "|Date|Phase|Status|" > "$INDEX"
echo "|---|---|---|" >> "$INDEX"

fi


echo "|$DATE|$PHASE|$STATUS|" >> "$INDEX"



cd "$BASE"

git add .

git commit \
-m "Evidence Pipeline V2 $PHASE $DATE" \
|| true


git push origin main \
|| true



echo
echo "PIPELINE COMPLETE"
echo "$OUT"



exit "$RESULT"

RUNNER



chmod +x "$PIPE/run.sh"



echo "Testing Pipeline V2"


"$PIPE/run.sh" \
"Pipeline V2 Test" \
"echo PIPELINE_V2_OK && sleep 2 && echo FINISHED"



echo "Sync finished"

