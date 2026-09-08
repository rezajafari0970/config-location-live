#!/usr/bin/env bash
set -Eeuo pipefail

REPO="/var/lib/config-location/devlog-github/repo"

echo "================================"
echo " FIX GIT FILTER REPO"
echo "================================"


if ! command -v git-filter-repo >/dev/null 2>&1
then

echo "[1] Installing git-filter-repo..."

apt-get update -y

apt-get install -y git-filter-repo

fi


echo "[2] Checking..."

git-filter-repo --version


cd "$REPO"


echo "[3] Removing large artifact from history..."

git filter-repo \
--path dev-context/config-model/config-model-audit-latest.txt \
--invert-paths \
--force


echo "[4] Cleaning..."

git reflog expire --expire=now --all

git gc --prune=now --aggressive


echo "[5] Checking large blobs..."

git rev-list --objects --all \
| git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' \
| awk '$3 > 50000000 {print}' \
|| true


echo "[6] Force push cleaned history..."

git push origin main --force


echo
echo "================================"
echo " FILTER REPO FIX COMPLETE"
echo "================================"

