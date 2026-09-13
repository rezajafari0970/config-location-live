#!/usr/bin/env bash

set -euo pipefail

BASE="/root/project-reports"
REPORT="$BASE/phase122-audit"
PIPE="$BASE/reports/pipeline"

echo "======================================"
echo " PHASE 1.2.2 RUNTIME EVIDENCE AUDIT"
echo "======================================"

mkdir -p "$REPORT"


echo "[1] Pipeline list"

find "$PIPE" \
-maxdepth 1 \
-type d \
-name "20*" \
| sort \
> "$REPORT/pipeline-list.txt"


LATEST=$(tail -n 1 "$REPORT/pipeline-list.txt" || true)

echo "$LATEST" > "$REPORT/latest-run.txt"



echo "[2] Collect evidence"

if [ -n "$LATEST" ] && [ -d "$LATEST" ]; then

cp "$LATEST/SUMMARY.md" \
"$REPORT/summary.txt" 2>/dev/null || true

cp "$LATEST/staged-files.txt" \
"$REPORT/staged.txt" 2>/dev/null || true

cp "$LATEST/verification.txt" \
"$REPORT/verification.txt" 2>/dev/null || true

fi



echo "[3] Git status"

cd "$BASE"

git status \
> "$REPORT/git-status.txt" \
2>&1 || true



echo "[4] Component check"

{

echo "UI COMPONENT CHECK"

for F in \
/opt/config-manager/panel/app/components/sidebar/sidebar.html \
/opt/config-manager/panel/app/components/cards/stat-card.html \
/opt/config-manager/panel/app/components/tables/data-table.html \
/opt/config-manager/panel/app/components/modal/modal.html \
/opt/config-manager/panel/app/components/alerts/alert.html \
/opt/config-manager/panel/app/components/notifications/toast.html

do

echo

echo "FILE:"
echo "$F"

if [ -f "$F" ]; then
echo "EXISTS=YES"
else
echo "EXISTS=NO"
fi

done

} > "$REPORT/component-check.txt"



echo "[5] Final report"


cat > "$REPORT/FINAL-REPORT.md" <<REPORT
# Phase 1.2.2 Runtime Evidence Audit


Generated:

$(date)


Latest Run:

$LATEST


Status:

COMPLETED

REPORT


echo "======================================"
echo " AUDIT COMPLETE"
echo "======================================"

