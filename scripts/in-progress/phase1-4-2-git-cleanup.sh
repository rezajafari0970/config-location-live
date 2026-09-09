#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="/var/lib/config-location/devlog-github/repo"
DEV="/var/lib/config-location/dev-assistant-v3"

echo "=============================================="
echo " PHASE 1.4.2 GIT CLEANUP + ARTIFACT POLICY"
echo "=============================================="


if [ ! -d "$REPO/.git" ]; then
    echo "ERROR: Git repository not found:"
    echo "$REPO"
    exit 1
fi


cd "$REPO"


echo "[1/8] Git repository check"

git rev-parse --is-inside-work-tree


echo "[2/8] Finding oversized files"


find . \
-type f \
-size +50M \
-not -path "./.git/*" \
-print \
> /tmp/git-large-files.txt || true


cat /tmp/git-large-files.txt || true


echo "[3/8] Removing large artifacts from index"


while read -r FILE
do

[ -z "$FILE" ] && continue

echo "Removing:"
echo "$FILE"

git rm --cached "$FILE" 2>/dev/null || true

done < /tmp/git-large-files.txt



echo "[4/8] Creating artifact policy"


mkdir -p \
"$REPO/dev-context/policy"


cat >"$REPO/dev-context/policy/artifact-policy.json" <<JSON
{
 "policy_version":1,

 "github":{
   "max_file_mb":50,
   "mode":"metadata_only"
 },

 "external_storage":{
   "provider":"google-drive",
   "large_files":true
 },

 "rules":[
   "never_commit_large_logs",
   "never_commit_raw_dumps",
   "keep_latest_context_only"
 ]
}
JSON



echo "[5/8] Updating gitignore"


cat >> .gitignore <<'IGNORE'

# Dev Context Large Artifacts
dev-context/**/history/
dev-context/**/raw/
dev-context/**/archive/
*.log
*.tar.gz
*.zip

IGNORE



echo "[6/8] Commit cleanup"


git add .gitignore \
dev-context/policy/artifact-policy.json


git commit \
-m "Phase 1.4.2 Artifact Policy and Git Cleanup $(date -Is)" \
|| echo "Nothing new to commit"



echo "[7/8] Push test"


git push origin main



echo "[8/8] Final status"


git status


echo
echo "=============================================="
echo " PHASE 1.4.2 COMPLETE"
echo "=============================================="

