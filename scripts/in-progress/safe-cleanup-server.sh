#!/bin/bash

set -e

echo "================================="
echo " SAFE SERVER CLEANUP"
echo "================================="


echo "[1] Disk before"
df -h


echo
echo "[2] Apt cache"

apt-get clean || true
apt-get autoclean || true



echo
echo "[3] System journal cleanup"

journalctl --vacuum-time=7d || true



echo
echo "[4] Temporary files"


find /tmp -type f -mtime +3 -delete 2>/dev/null || true
find /var/tmp -type f -mtime +3 -delete 2>/dev/null || true



echo
echo "[5] Core dumps"

rm -rf /var/lib/systemd/coredump/* 2>/dev/null || true



echo
echo "[6] Python cache"

find /opt \
-type d \
-name "__pycache__" \
-prune \
-exec rm -rf {} + 2>/dev/null || true


find /opt \
-type f \
-name "*.pyc" \
-delete 2>/dev/null || true



echo
echo "[7] Old logs"

find /opt \
-type f \
-name "*.log" \
-size +10M \
-delete 2>/dev/null || true



echo
echo "[8] Old archives in root"

find /root \
-type f \
\( \
-name "*.tar.gz" \
-o -name "*.tar" \
-o -name "*.zip" \
\) \
-size +100M \
-print



echo
echo "[9] Docker cleanup if exists"

if command -v docker >/dev/null 2>&1
then
docker system prune -af || true
fi



echo
echo "[10] Remove old aop test snapshots"

if [ -d /root/aop ]
then

find /root/aop \
-type f \
-name "*.tar.gz" \
-size +300M \
-print

fi



echo
echo "[11] Disk after"

df -h


echo
echo "DONE"

