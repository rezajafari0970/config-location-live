#!/bin/bash

set -Eeuo pipefail

SRC="/root/only-source-code-final"

DATE=$(date +%Y%m%d-%H%M%S)

OUT="/root/aop/only-source-code-final-full-${DATE}.tar.zst"

REPORT="/root/aop/only-source-code-final-full-${DATE}-report"

mkdir -p /root/aop
mkdir -p "$REPORT"


echo "===== ONLY SOURCE CODE FINAL FULL PACK ====="


echo "[1] File list"

find "$SRC" -printf "%p\n" \
| sort \
> "$REPORT/file-list.txt"


echo "[2] Size map"

du -ah "$SRC" \
| sort -hr \
> "$REPORT/size-map.txt"


echo "[3] Archive"


tar \
--numeric-owner \
-cf - \
-C /root \
only-source-code-final \
| zstd -15 -T0 \
-o "$OUT"


echo "[4] SHA256"

sha256sum "$OUT" > "$OUT.sha256"


echo "[5] Archive verify"

tar -tf "$OUT" \
> "$REPORT/archive-list.txt"


echo "[6] Summary"

{
echo "ONLY SOURCE CODE FINAL"
echo
echo "Created:"
date
echo
echo "Archive:"
echo "$OUT"
echo
echo "Size:"
ls -lh "$OUT"
echo
echo "Files:"
find "$SRC" -type f | wc -l

} > "$REPORT/summary.txt"


echo
echo "DONE"

ls -lh "$OUT"
echo "$OUT.sha256"
echo "$REPORT"

