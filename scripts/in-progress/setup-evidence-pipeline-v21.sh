#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

PIPE="$BASE/scripts/pipeline/run.sh"


echo "======================================"
echo " EVIDENCE PIPELINE V2.1"
echo " SELF VERIFICATION"
echo "======================================"



if [ ! -f "$PIPE" ]; then
    echo "Pipeline V2 not found"
    exit 1
fi



python3 - <<'PY'
from pathlib import Path

p = Path("/root/project-reports/scripts/pipeline/run.sh")

data = p.read_text()


data = data.replace(
'''git push origin main \\
|| true


echo
echo "PIPELINE COMPLETE"
echo "$OUT"


exit "$RESULT"
''',
'''git push origin main \\
|| true



echo "[VERIFY]"


VERIFY="$OUT/verification.txt"



{
echo "EVIDENCE PIPELINE V2.1 VERIFICATION"
echo

echo "Report Directory:"
echo "$OUT"

echo


if [ -f "$OUT/SUMMARY.md" ]; then
    echo "SUMMARY: OK"
else
    echo "SUMMARY: FAILED"
fi


if [ -f "$OUT.tar.gz" ]; then
    echo "ARCHIVE: OK"
else
    echo "ARCHIVE: FAILED"
fi


echo

echo "Git Commit:"
git rev-parse HEAD 2>/dev/null || echo "FAILED"


echo

echo "Git Status:"
git status --short 2>/dev/null || true


echo

echo "Repository:"
git remote -v 2>/dev/null || true


} > "$VERIFY"



if grep -q "FAILED" "$VERIFY"
then
    VERIFY_STATUS="FAILED"
else
    VERIFY_STATUS="SUCCESS"
fi



echo

echo "VERIFICATION STATUS:"
echo "$VERIFY_STATUS"


echo "$VERIFY_STATUS" >> "$VERIFY"



cd "$BASE"


git add "$OUT"

git commit \
-m "Pipeline V2.1 verification $DATE" \
|| true


git push origin main \
|| true



echo
echo "PIPELINE V2.1 COMPLETE"
echo "$VERIFY"



exit "$RESULT"
'''
)


p.write_text(data)

PY



echo "[1] Pipeline patched"



echo "[2] Running self test"



"$PIPE" \
"Pipeline V2.1 Self Test" \
"echo SELF_VERIFY_START && sleep 2 && echo SELF_VERIFY_DONE"



echo

echo "======================================"
echo " V2.1 READY"
echo "======================================"

