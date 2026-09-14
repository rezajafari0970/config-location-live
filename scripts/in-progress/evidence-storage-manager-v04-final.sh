#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

CACHE="/root/project-cache"


echo "======================================"
echo " EVIDENCE STORAGE MANAGER V0.4 FINAL"
echo " PIPELINE V2.3 MODE"
echo "======================================"



echo "[1] Cache structure"



mkdir -p "$CACHE"/{
executions,
archives,
snapshots,
logs,
packages,
index
}



echo "[2] Cache Manager"



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

echo "Size:"

du -sh "$CACHE"


} > "$REPORT"

SCRIPT



chmod +x "$BASE/scripts/cache-manager.sh"



echo "[3] Rotation Manager"



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



echo "[4] GitHub Cache Policy"



cat > "$BASE/cache-index.md" <<DOC
# Evidence Cache Index


## Stored in GitHub

- Code
- Documentation
- Reports
- Verification


## Stored in Cache

- Logs
- Archives
- Snapshots
- Large Evidence


Generated:

$(date)

DOC



echo "[5] Run Cache Report"



"$BASE/scripts/cache-manager.sh"



echo "[6] Storage Report"



cat > "$BASE/storage-manager-v04-report.md" <<DOC
# Evidence Storage Manager V0.4


Status:

READY


Cache:

$CACHE


Generated:

$(date)

DOC



echo

echo "======================================"
echo " STORAGE MANAGER COMPLETE"
echo "======================================"

