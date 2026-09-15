#!/bin/bash

set -Eeuo pipefail

SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

WORK="/tmp/config-location-clean-$DATE"

OUT="$BASE/config-location-production-clean-$DATE.tar.zst"


mkdir -p "$WORK"


echo "===== Extract ====="

tar -xzf "$SRC" -C "$WORK"


ROOT=$(find "$WORK" -mindepth 1 -maxdepth 1 -type d | head -1)


REPORT="$BASE/config-clean-report-$DATE"

mkdir -p "$REPORT"


echo "===== Size Before ====="

du -h --max-depth=2 "$ROOT" | sort -h \
> "$REPORT/before-size.txt"



echo "===== Find removable ====="

find "$ROOT" \
\( \
-name "venv" \
-o -name ".venv" \
-o -name "__pycache__" \
-o -name "*.pyc" \
-o -name "*.pyo" \
-o -name "*.log" \
-o -name "logs" \
-o -name "backups" \
-o -name "backup" \
-o -name "*.tar.gz" \
-o -name "*.tar" \
-o -name "*.zip" \
-o -name "archive" \
-o -name "gdrive-SNAPSHOT*" \
-o -name "snapshot*" \
\) \
-print \
> "$REPORT/remove-list.txt"



echo "===== Remove ====="

while read -r F
do
    [ -e "$F" ] && rm -rf "$F"
done < "$REPORT/remove-list.txt"



echo "===== Large files ====="

find "$ROOT" \
-type f \
-size +20M \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/large-files.txt"



echo "===== Size After ====="

du -h --max-depth=2 "$ROOT" | sort -h \
> "$REPORT/after-size.txt"



echo "===== Compress ZSTD ====="

tar --zstd -19 -cf "$OUT" \
-C "$WORK" \
"$(basename "$ROOT")"



echo "===== SHA256 ====="

sha256sum "$OUT" > "$OUT.sha256"



echo
echo "DONE"
echo "$OUT"
echo "$OUT.sha256"

echo
echo "REPORT"
echo "$REPORT"


rm -rf "$WORK"

