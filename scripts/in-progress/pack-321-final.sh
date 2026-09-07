#!/bin/bash

set -e

SRC="/root/321"
DATE=$(date +%Y%m%d-%H%M%S)

OUT="/root/321/ONLY-SOURCE-CODE-FINAL-MASTER-${DATE}.tar.zst"

REPORT="/root/321/MASTER-PACK-REPORT-${DATE}"

mkdir -p "$REPORT"

echo "===== MASTER PACK 321 ====="


echo "[1] File list"

find "$SRC" -maxdepth 1 -printf "%f\n" \
> "$REPORT/file-list.txt"


echo "[2] Size"

du -ah "$SRC" \
| sort -hr \
> "$REPORT/size-map.txt"


echo "[3] Compress"

tar \
--numeric-owner \
-cf - \
-C /root \
321 \
| zstd -15 -T0 \
-o "$OUT"


echo "[4] SHA256"

sha256sum "$OUT" > "$OUT.sha256"


echo "[5] Verify"

tar -I zstd -tf "$OUT" \
> "$REPORT/archive-list.txt"


echo "[6] Summary"

{
echo "ONLY SOURCE CODE FINAL MASTER"
echo
date
echo
echo "Archive:"
echo "$OUT"
echo
echo "Size:"
ls -lh "$OUT"

} > "$REPORT/summary.txt"


echo
echo "DONE"

ls -lh "$OUT"
echo "$OUT.sha256"
echo "$REPORT"

