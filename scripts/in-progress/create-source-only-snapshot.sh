#!/bin/bash
set -e

DATE=$(date +%Y%m%d-%H%M%S)

OUT="/root/aop/config-location-source-only-${DATE}.tar.zst"
REPORT="/root/aop/config-location-source-only-${DATE}-report"

mkdir -p "$REPORT"

echo "===== SOURCE ONLY SNAPSHOT ====="

SRC="/opt/config-location"

echo "[1] Collect source"

tar -cf - \
--exclude="$SRC/venv" \
--exclude="$SRC/backups" \
--exclude="$SRC/__pycache__" \
--exclude="$SRC/*.log" \
--exclude="$SRC/.git" \
--exclude="$SRC/.cache" \
-C /opt \
config-location \
| zstd -15 -T0 -o "$OUT"

echo "[2] SHA256"

sha256sum "$OUT" > "$OUT.sha256"

echo "[3] Report"

tar -tf "$OUT" > "$REPORT/files.txt"

du -sh "$OUT" > "$REPORT/size.txt"

wc -l "$REPORT/files.txt" > "$REPORT/file-count.txt"

echo
echo "DONE"
ls -lh "$OUT"
echo "$OUT"
echo "$OUT.sha256"
echo "$REPORT"

