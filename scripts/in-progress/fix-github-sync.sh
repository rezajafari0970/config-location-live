#!/usr/bin/env bash

set -euo pipefail

REPO="/root/project-reports"

echo "======================================"
echo " FIX GITHUB SYNC PIPELINE "
echo "======================================"

cd "$REPO"


echo "[1] Checking git state..."

CURRENT=$(git branch --show-current || true)

echo "Current branch: $CURRENT"


echo "[2] Saving current state..."

git branch backup-before-fix-$(date +%Y%m%d-%H%M%S) 2>/dev/null || true


echo "[3] Moving to main branch..."

git checkout -B main


echo "[4] Fetching remote..."

git fetch origin


echo "[5] Merging remote changes..."

git merge origin/main --allow-unrelated-histories -m "Merge GitHub initial state" || {

echo "Merge conflict detected"

git checkout --ours README.md 2>/dev/null || true

git add .

git commit -m "Resolve GitHub sync conflict" || true

}


echo "[6] Push main..."

git push origin main --force


echo "[7] Updating sync script..."


cat > "$REPO/scripts/sync-project.sh" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

BASE="/root/project-reports"

echo "SYNC START"

cd "$BASE"


echo "[1] Ensure main branch"

git checkout main


echo "[2] Update remote"

git fetch origin


echo "[3] Generate report"

/root/project-reports/scripts/generate-report.sh


echo "[4] Add files"

git add .


echo "[5] Commit"

git commit \
-m "Automatic evidence update $(date +%Y-%m-%d-%H%M%S)" \
|| true


echo "[6] Push"

git push origin main


echo "SYNC COMPLETE"

SCRIPT


chmod +x "$REPO/scripts/sync-project.sh"


echo
echo "======================================"
echo " GITHUB SYNC FIXED "
echo "======================================"

git status

