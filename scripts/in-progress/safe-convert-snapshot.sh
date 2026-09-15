#!/bin/bash

set -Eeuo pipefail

BASE="/root/aop"

SRC="$BASE/config-location-production-audit-20260904-021830.tar.gz"

OUT="$BASE/config-location-production-audit-20260904-021830.tar.zst"

echo "================================="
echo " SAFE SNAPSHOT CONVERTER"
echo "================================="


echo "[1] Cleaning failed temporary files"

rm -rf /tmp/config-location-* 2>/dev/null || true
rm -rf "$BASE/convert-work" 2>/dev/null || true


echo "[2] Disk status"

df -h


if [ ! -f "$SRC" ]; then
    echo "ERROR: source file not found"
    exit 1
fi


echo "[3] Installing zstd"

if ! command -v zstd >/dev/null 2>&1
then
    apt update
    apt install -y zstd
fi


echo "[4] Removing old output"

rm -f "$OUT"
rm -f "$OUT.sha256"


echo "[5] Direct streaming conversion"

echo "FROM:"
ls -lh "$SRC"

echo "TO:"
echo "$OUT"


gzip -dc "$SRC" \
| zstd -19 -T0 \
-o "$OUT"



echo "[6] SHA256"

sha256sum "$OUT" > "$OUT.sha256"



echo "[7] Verify archive"

tar --zstd -tf "$OUT" \
> /tmp/zstd-check-list.txt


COUNT=$(wc -l < /tmp/zstd-check-list.txt)


echo "Files inside:"
echo "$COUNT"


echo "[8] Final size"

ls -lh "$OUT"
ls -lh "$OUT.sha256"


echo
echo "DONE"

