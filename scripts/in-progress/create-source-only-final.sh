#!/bin/bash
set -e

DATE=$(date +%Y%m%d-%H%M%S)

WORK="/tmp/config-location-source-clean"
OUT="/root/aop/config-location-source-only-final-${DATE}.tar.zst"
REPORT="/root/aop/config-location-source-only-final-${DATE}-report"

rm -rf "$WORK"
mkdir -p "$WORK" "$REPORT"

echo "[1] Copy clean source"

rsync -a \
--exclude venv \
--exclude backups \
--exclude __pycache__ \
--exclude '*.pyc' \
--exclude '*.log' \
--exclude .git \
/opt/config-location/ \
"$WORK/config-location/"


echo "[2] Check"

find "$WORK" > "$REPORT/files-before.txt"


echo "[3] Compress"

tar -C "$WORK" -cf - config-location \
| zstd -10 -T0 -o "$OUT"


echo "[4] SHA"

sha256sum "$OUT" > "$OUT.sha256"


echo "[5] Verify"

tar -tf "$OUT" > "$REPORT/archive-files.txt"

grep -E "venv|backups|__pycache__|\.pyc|\.log" \
"$REPORT/archive-files.txt" \
> "$REPORT/problem.txt" || true


echo
echo DONE
ls -lh "$OUT"
echo "$OUT.sha256"
echo "$REPORT"

rm -rf "$WORK"

