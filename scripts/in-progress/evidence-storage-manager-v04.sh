#!/usr/bin/env bash

set -euo pipefail


BASE="/root/project-reports"

CACHE="/root/project-cache"


echo "======================================"
echo " EVIDENCE STORAGE MANAGER V0.4"
echo " CACHE + ROTATION + GITHUB POLICY"
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



echo "[2] Git ignore policy"



cd "$BASE"



touch .gitignore



cat >> .gitignore <<'IGNORE'

# Evidence large files

reports/pipeline/*/*.log
reports/pipeline/*.tar.gz

# Cache

project-cache/
cache/
archives/
snapshots/
packages/


IGNORE



echo "[3] Cache manager script"



mkdir -p "$BASE/scripts"



cat > "$BASE/scripts/cache-manager.sh" <<'SCRIPT'
#!/usr/bin/env bash


set -euo pipefail


CACHE="/root/project-cache"

REPORT="/root/project-cache/index/cache-report.md"



mkdir -p "$CACHE/index"



echo "# Cache Report" > "$REPORT"

echo >> "$REPORT"

date >> "$REPORT"



echo >> "$REPORT"

echo "## Archive Files" >> "$REPORT"


find "$CACHE" \
-type f \
-printf "%p | %s bytes\n" \
>> "$REPORT"



echo >> "$REPORT"

echo "## Total Size" >> "$REPORT"


du -sh "$CACHE" >> "$REPORT"



SCRIPT



chmod +x "$BASE/scripts/cache-manager.sh"



echo "[4] Rotation policy"



cat > "$BASE/scripts/cache-rotate.sh" <<'SCRIPT'
#!/usr/bin/env bash


set -euo pipefail


CACHE="/root/project-cache"


DAYS=30



find "$CACHE" \
-type f \
-mtime +$DAYS \
-print \
>> "$CACHE/index/rotation.log"



SCRIPT



chmod +x "$BASE/scripts/cache-rotate.sh"



echo "[5] Initial cache report"



"$BASE/scripts/cache-manager.sh"



echo "[6] Create GitHub cache index"



cat > "$BASE/cache-index.md" <<REPORT
# Cache Index


## Policy


GitHub stores:

- Code
- Documentation
- Summary
- Verification


Local Cache stores:

- Logs
- Archives
- Snapshots
- Large Evidence Files


Generated:

$(date)

REPORT



echo "[7] Commit policy"



git add .


git commit \
-m "Evidence Storage Manager V0.4" \
|| true


git push origin main \
|| true



echo

echo "======================================"
echo " STORAGE MANAGER READY"
echo "======================================"

