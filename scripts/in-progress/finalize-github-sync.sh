#!/usr/bin/env bash

set -euo pipefail

REPO="/root/project-reports"

echo "================================"
echo " FINALIZE GITHUB SYNC "
echo "================================"

cd "$REPO"


echo "[1] Abort old rebase if exists"

git rebase --abort 2>/dev/null || true


echo "[2] Ensure main branch"

git checkout main


echo "[3] Fetch github"

git fetch origin


echo "[4] Backup current state"

git branch backup-before-finalize-$(date +%Y%m%d-%H%M%S) || true


echo "[5] Make local main clean"

git reset --hard HEAD


echo "[6] Force push server history"

git push origin main --force


echo "[7] Verify"

git status

git log --oneline -5


echo
echo "================================"
echo " GITHUB SYNC FINALIZED "
echo "================================"

