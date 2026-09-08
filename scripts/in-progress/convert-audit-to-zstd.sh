#!/bin/bash

set -Eeuo pipefail

SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

OUT="/root/aop/config-location-production-audit-20260904-021830.tar.zst"


echo "================================"
echo " TAR.GZ -> TAR.ZST CONVERTER"
echo "================================"


if [ ! -f "$SRC" ]; then
    echo "ERROR: source file not found"
    exit 1
fi


echo "[1] Checking disk"

df -h /root/aop


echo "[2] Installing zstd if needed"

if ! command -v zstd >/dev/null 2>&1
then
    apt update
    apt install -y zstd
fi


echo "[3] Converting..."

gzip -dc "$SRC" | zstd -19 -T0 -o "$OUT"


echo "[4] Creating SHA256"

sha256sum "$OUT" > "$OUT.sha256"


echo "[5] Testing archive"

mkdir -p /tmp/zstd-test-check

tar --zstd -tf "$OUT" \
> /tmp/zstd-test-check/file-list.txt


COUNT=$(wc -l < /tmp/zstd-test-check/file-list.txt)


echo
echo "Files inside:"
echo "$COUNT"


echo
echo "[6] Size comparison"

ls -lh "$SRC"
ls -lh "$OUT"


echo
echo "DONE"

echo "$OUT"
echo "$OUT.sha256"

