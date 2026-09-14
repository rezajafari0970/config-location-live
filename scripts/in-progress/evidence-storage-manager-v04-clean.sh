#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

CACHE="/root/project-cache"


echo "======================================"
echo " EVIDENCE STORAGE MANAGER V0.4"
echo " CENTRAL PIPELINE MODE"
echo "======================================"



echo "[1] Create cache structure"


mkdir -p "$CACHE"/{
executions,
archives,
snapshots,
logs,
packages,
index
}



echo "[2] Create cache manager"



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

echo "Generated:"
date

echo

echo "Files:"

find "$CACHE" \
-type f \
-printf "%p | %s bytes\n"

echo

echo "Total Size:"

du -sh "$CACHE"

} > "$REPORT"

SCRIPT



chmod +x "$BASE/scripts/cache-manager.sh"



echo "[3] Create rotation manager"



cat > "$BASE/scripts/cache-rotate.sh" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail


CACHE="/root/project-cache"

LOG="$CACHE/index/rotation.log"



find "$CACHE" \
-type f \
-mtime +30 \
>> "$LOG" 2>/dev/null || true

SCRIPT



chmod +x "$BASE/scripts/cache-rotate.sh"



echo "[4] GitHub policy index"



cat > "$BASE/cache-index.md" <<DOC
# Evidence Cache Index


## GitHub Keeps

- Source Code
- Documentation
- Summary
- Verification Reports


## Local Cache Keeps

- Large Logs
- Archives
- Snapshots
- Package Cache


Generated:

$(date)

DOC



echo "[5] Run cache report"



"$BASE/scripts/cache-manager.sh"



echo "[6] Create verification report"



cat > "$BASE/storage-manager-v04-report.md" <<DOC
# Storage Manager V0.4


Status:

READY


Cache:

$CACHE


Generated:

$(date)

DOC



echo

echo "======================================"
echo " STORAGE MANAGER READY"
echo "======================================"

