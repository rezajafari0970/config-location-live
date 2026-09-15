#!/bin/bash
set -e

DATE=$(date +%Y%m%d-%H%M%S)

OUT="/root/aop/config-location-source-only-v2-${DATE}.tar.zst"
REPORT="/root/aop/config-location-source-only-v2-${DATE}-report"

SRC="/opt/config-location"

mkdir -p "$REPORT"

echo "===== SOURCE ONLY V2 ====="

echo "[1] Checking source"

find "$SRC" \
-not -path "$SRC/venv*" \
-not -path "$SRC/backups*" \
-not -path "*/__pycache__*" \
-not -name "*.pyc" \
-not -name "*.log" \
> "$REPORT/source-files.txt"


echo "[2] Creating archive"

tar \
--exclude='./config-location/venv' \
--exclude='./config-location/backups' \
--exclude='*/__pycache__/*' \
--exclude='*.pyc' \
--exclude='*.log' \
--exclude='./config-location/.git' \
-cf - \
-C /opt \
config-location \
| zstd -10 -T0 -o "$OUT"


echo "[3] SHA256"

sha256sum "$OUT" > "$OUT.sha256"


echo "[4] Verify archive content"

tar -tf "$OUT" > "$REPORT/archive-files.txt"

grep -E "venv|backups|__pycache__|\.pyc|\.log" \
"$REPORT/archive-files.txt" \
> "$REPORT/forbidden-found.txt" || true


echo "[5] Stats"

wc -l "$REPORT/archive-files.txt" > "$REPORT/file-count.txt"
ls -lh "$OUT" > "$REPORT/size.txt"


echo
echo "DONE"
ls -lh "$OUT"
echo "$OUT.sha256"
echo "$REPORT"

