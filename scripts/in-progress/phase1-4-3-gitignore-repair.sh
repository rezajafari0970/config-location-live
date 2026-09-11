#!/usr/bin/env bash
set -Eeuo pipefail

REPO="/var/lib/config-location/devlog-github/repo"

cd "$REPO"

echo "================================"
echo " GITIGNORE POLICY REPAIR"
echo "================================"


cat > .gitignore <<'IGNORE'
# Large development artifacts only

dev-context/**/history/
dev-context/**/raw/
dev-context/**/archive/

*.log
*.tar.gz
*.zip

# Keep Dev Context metadata
!dev-context/
!dev-context/**
IGNORE


echo "[1] Adding policy..."

git add -f \
dev-context/policy/artifact-policy.json \
2>/dev/null || true


echo "[2] Adding gitignore..."

git add .gitignore


echo "[3] Commit..."

git commit \
-m "Repair Dev Context gitignore policy $(date -Is)" \
|| echo "Nothing to commit"


echo "[4] Push..."

git push origin main


echo "[5] Status..."

git status


echo "================================"
echo " GITIGNORE REPAIR COMPLETE"
echo "================================"

