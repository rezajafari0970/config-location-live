#!/bin/bash

set -Eeuo pipefail

echo "================================="
echo " CLEAN SNAPSHOT TEMP SPACE"
echo "================================="


echo "[1] Stop snapshot processes"

pkill -f "snapshot" 2>/dev/null || true
pkill -f "rsync" 2>/dev/null || true
pkill -f "zstd" 2>/dev/null || true
pkill -f "tar" 2>/dev/null || true


echo "[2] Remove temporary builds"


rm -rf /root/config-location-*
rm -rf /root/work-*
rm -rf /root/tmp-*

rm -rf /tmp/config-location-*
rm -rf /tmp/config-*
rm -rf /tmp/work-*


echo "[3] Clean failed snapshot folders in aop"


if [ -d /root/aop ]; then

find /root/aop \
-maxdepth 1 \
-type d \
\( \
-name "work*" \
-o -name "convert-work" \
-o -name "*report*" \
\) \
-print \
-exec rm -rf {} +

fi



echo "[4] Remove broken small archives"


if [ -d /root/aop ]; then

find /root/aop \
-maxdepth 1 \
-type f \
-size -1M \
\( \
-name "*.tar.zst" \
-o -name "*.tar.gz" \
\) \
-print \
-delete

fi



echo "[5] Clear package cache"

apt-get clean 2>/dev/null || true



echo "[6] Journal cleanup"

journalctl --vacuum-time=7d 2>/dev/null || true



echo "[7] Python cache cleanup"

find /opt \
-type d \
-name "__pycache__" \
-prune \
-exec rm -rf {} + 2>/dev/null || true



echo "[8] Disk status"

df -h



echo
echo "DONE"

