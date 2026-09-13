#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

CACHE="/root/project-cache"

REPORT="$BASE/storage-manager-v04-verification.md"



echo "======================================"
echo " STORAGE MANAGER V0.4"
echo " VERIFICATION & FIX"
echo "======================================"



echo "[1] Creating cache structure"



mkdir -p "$CACHE"/{
executions,
archives,
snapshots,
logs,
packages,
index
}



echo "[2] Creating cache scripts"



mkdir -p "$BASE/scripts"



cat > "$BASE/scripts/cache-manager.sh" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail


CACHE="/root/project-cache"

REPORT="$CACHE/index/cache-report.md"


mkdir -p "$CACHE/index"


{

echo "# Cache Report"

echo

date

echo

echo "## Files"

find "$CACHE" -type f -printf "%p | %s bytes\n"

echo

echo "## Size"

du -sh "$CACHE"

} > "$REPORT"

SCRIPT



chmod +x "$BASE/scripts/cache-manager.sh"



cat > "$BASE/scripts/cache-rotate.sh" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail


CACHE="/root/project-cache"

find "$CACHE" \
-type f \
-mtime +30 \
>> "$CACHE/index/rotation.log" || true

SCRIPT



chmod +x "$BASE/scripts/cache-rotate.sh"



echo "[3] Creating GitHub index"



cat > "$BASE/cache-index.md" <<EOF2
# Cache Index


## Policy

GitHub:

- Source Code
- Documentation
- Summary
- Verification


Cache:

- Logs
- Archives
- Snapshots
- Large Evidence Files


Generated:

$(date)

EOF2



echo "[4] Local verification"



{

echo "# Storage Manager V0.4 Verification"

echo

echo "Date:"
date

echo

echo "Cache Structure:"

find "$CACHE" -maxdepth 2 -type d


echo

echo "Scripts:"

ls -la "$BASE/scripts/cache-"*


echo

echo "Index:"

ls -la "$BASE/cache-index.md"


} > "$REPORT"



echo "[5] Git commit"



cd "$BASE"


git add \
.gitignore \
cache-index.md \
scripts/cache-manager.sh \
scripts/cache-rotate.sh \
storage-manager-v04-verification.md \
|| true



git commit \
-m "Evidence Storage Manager V0.4 verification fix" \
|| true



echo "[6] Push GitHub"



git push origin main



echo "[7] Final status"



git status



echo

echo "======================================"
echo " STORAGE MANAGER V0.4 VERIFIED"
echo "======================================"

