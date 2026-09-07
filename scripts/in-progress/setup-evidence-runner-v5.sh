#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"
RUNNER="$BASE/scripts/run-evidence.sh"


echo "======================================"
echo " INSTALL EVIDENCE RUNNER V5"
echo " LIVE OUTPUT + FULL CAPTURE"
echo "======================================"


mkdir -p "$BASE/scripts"



cat > "$RUNNER" <<'RUNNER'
#!/usr/bin/env bash

set -uo pipefail


BASE="/root/project-reports"

EXEC_DIR="$BASE/reports/executions"

DATE=$(date +"%Y%m%d-%H%M%S")

OUT="$EXEC_DIR/$DATE"


mkdir -p "$OUT"



if [ $# -lt 1 ]; then
    echo "Usage: $0 \"command\""
    exit 1
fi



CMD="$*"

START=$(date +%s)



echo "======================================"
echo " EVIDENCE RUNNER V5"
echo " LIVE EXECUTION"
echo "======================================"

echo

echo "COMMAND:"
echo "$CMD"

echo



echo "$CMD" > "$OUT/command.txt"

date -Is > "$OUT/start-time.txt"



{
echo "SYSTEM BEFORE"
echo
date
echo
free -h
echo
df -h
echo
uptime

} > "$OUT/system-before.txt"



echo "===== LIVE OUTPUT START ====="



bash -c "$CMD" \
2> >(tee "$OUT/stderr.log" >&2) \
| tee "$OUT/stdout.log"



EXIT_CODE=${PIPESTATUS[0]}



END=$(date +%s)

DURATION=$((END-START))



echo "$EXIT_CODE" > "$OUT/exit-code.txt"

date -Is > "$OUT/end-time.txt"



{
echo "SYSTEM AFTER"
echo
date
echo
free -h
echo
df -h
echo
ss -lntup

} > "$OUT/system-after.txt"



if [ "$EXIT_CODE" -eq 0 ]
then
STATUS="SUCCESS"
else
STATUS="FAILED"
fi



echo "$STATUS" > "$OUT/status.txt"



cat > "$OUT/SUMMARY.md" <<SUMMARY
# Execution Summary

Command:

$CMD


Status:

$STATUS


Exit Code:

$EXIT_CODE


Duration:

${DURATION}s


Time:

$(date)

SUMMARY



echo

echo "======================================"
echo " EXECUTION FINISHED"
echo "======================================"

echo "STATUS: $STATUS"

echo "REPORT:"
echo "$OUT"


exit "$EXIT_CODE"

RUNNER



chmod +x "$RUNNER"



echo "[1] Runner installed"



echo "[2] Running live test"



"$RUNNER" \
"echo LIVE TEST START && sleep 2 && echo LIVE TEST END"



echo "[3] Running Observer"



"$BASE/scripts/evidence-observer-v2.sh"



echo "[4] GitHub Sync"



"$BASE/scripts/sync-project.sh"



echo

echo "======================================"
echo " EVIDENCE RUNNER V5 READY"
echo "======================================"

