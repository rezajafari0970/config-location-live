#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

REPORT="$BASE/git-forensic"


echo "======================================"
echo " GIT FORENSIC AUDIT V1"
echo " READ ONLY ANALYSIS"
echo "======================================"



mkdir -p "$REPORT"



echo "[1] Git Root"



cd "$BASE"


git rev-parse --show-toplevel \
> "$REPORT/git-root.txt" \
2>&1 || true



echo "[2] Remote"



git remote -v \
> "$REPORT/remote.txt" \
2>&1 || true



echo "[3] Branch"



git branch --show-current \
> "$REPORT/branch.txt" \
2>&1 || true



echo "[4] HEAD"



git rev-parse HEAD \
> "$REPORT/head.txt" \
2>&1 || true



echo "[5] Status"



git status \
> "$REPORT/status.txt" \
2>&1 || true



echo "[6] Tracked Files"



git ls-files \
> "$REPORT/tracked.txt" \
2>&1 || true



echo "[7] Ignored Files"



git status --ignored \
> "$REPORT/ignored.txt" \
2>&1 || true



echo "[8] Untracked Files"



git ls-files --others --exclude-standard \
> "$REPORT/untracked.txt" \
2>&1 || true



echo "[9] Git Config"



git config --list \
> "$REPORT/config.txt" \
2>&1 || true



echo "[10] Final Report"



cat > "$REPORT/FINAL-REPORT.md" <<REPORT
# Git Forensic Audit V1


Generated:

$(date)


Repository:

$(cat "$REPORT/git-root.txt")


Branch:

$(cat "$REPORT/branch.txt")


HEAD:

$(cat "$REPORT/head.txt")


Remote:

$(cat "$REPORT/remote.txt")


Audit:

COMPLETED


Mode:

READ ONLY

REPORT



echo

echo "======================================"
echo " GIT FORENSIC AUDIT COMPLETE"
echo "======================================"

