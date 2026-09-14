#!/bin/bash

set -Eeuo pipefail

SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

OUTDIR="/root/aop"

NAME="config-location-production-audit-optimized-$(date +%Y%m%d-%H%M%S)"

WORK="/tmp/$NAME"

OUT="$OUTDIR/$NAME.tar.zst"


echo "===================================="
echo " SNAPSHOT OPTIMIZER"
echo "===================================="


if [ ! -f "$SRC" ]; then
    echo "ERROR: Snapshot not found"
    exit 1
fi


mkdir -p "$WORK"


echo "[1] Extracting snapshot"

tar -xzf "$SRC" -C "$WORK"


echo "[2] Size before"

du -sh "$WORK" > "$WORK/BEFORE-SIZE.txt"


echo "[3] Finding removable files"

find "$WORK" \
\( \
-name "*.tar.gz" \
-o -name "*.tar" \
-o -name "*.zip" \
-o -name "backup" \
-o -name "backups" \
-o -name "archive" \
-o -name "gdrive-SNAPSHOT*" \
\) \
-print \
> "$WORK/REMOVED-FILES.txt"



echo "[4] Removing internal archives"

while read -r F
do
    [ -e "$F" ] && rm -rf "$F"
done < "$WORK/REMOVED-FILES.txt"



echo "[5] Cleaning python/cache"

find "$WORK" \
\( \
-name "venv" \
-o -name ".venv" \
-o -name "__pycache__" \
-o -name "*.pyc" \
-o -name "*.pyo" \
\) \
-print \
>> "$WORK/REMOVED-FILES.txt"



while read -r F
do
    [ -e "$F" ] && rm -rf "$F"
done < "$WORK/REMOVED-FILES.txt"



echo "[6] Size after"

du -sh "$WORK" > "$WORK/AFTER-SIZE.txt"



echo "[7] Creating zstd archive"

tar --zstd -19 -cf "$OUT" \
-C "$(dirname "$WORK")" \
"$(basename "$WORK")"



echo "[8] SHA256"

sha256sum "$OUT" > "$OUT.sha256"



echo "[9] Final size"

ls -lh "$OUT"



echo
echo "DONE"
echo "$OUT"
echo "$OUT.sha256"


rm -rf "$WORK"

