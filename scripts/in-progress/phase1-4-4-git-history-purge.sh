#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="/var/lib/config-location/devlog-github/repo"

echo "=============================================="
echo " PHASE 1.4.4 GIT HISTORY PURGE"
echo "=============================================="


cd "$REPO"


echo "[1/8] Checking repository..."

git rev-parse --is-inside-work-tree


echo "[2/8] Installing git-filter-repo if needed..."

if ! command -v git-filter-repo >/dev/null 2>&1
then
    apt-get update -y
    apt-get install -y python3-pip
    pip3 install git-filter-repo
fi


echo "[3/8] Creating backup..."

tar czf \
"/root/dev-github-before-history-purge-$(date +%Y%m%d-%H%M%S).tar.gz" \
.git


echo "[4/8] Removing oversized artifact from history..."


git filter-repo \
--path dev-context/config-model/config-model-audit-latest.txt \
--invert-paths \
--force


echo "[5/8] Cleaning old objects..."

git reflog expire --expire=now --all

git gc \
--prune=now \
--aggressive


echo "[6/8] Checking large objects..."

git rev-list --objects --all \
| git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' \
| awk '$3 > 50000000 {print}' \
> /tmp/git-large-after-clean.txt || true


cat /tmp/git-large-after-clean.txt || true


echo "[7/8] Push cleaned history..."

git push origin main --force


echo "[8/8] Final status..."

git status


echo
echo "=============================================="
echo " HISTORY PURGE COMPLETE"
echo "=============================================="

