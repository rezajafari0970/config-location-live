#!/bin/bash

OUT="/root/server-failure-analysis-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee -a "$OUT") 2>&1

echo "=============================="
echo " SERVER FAILURE ANALYSIS"
echo "$(date)"
echo "=============================="

echo
echo "===== UPTIME ====="
uptime

echo
echo "===== LAST BOOT ====="
who -b

echo
echo "===== FAILED SERVICES ====="
systemctl --failed --no-pager

echo
echo "===== EMERGENCY / BOOT ERRORS ====="
journalctl -xb -p err --no-pager

echo
echo "===== PREVIOUS BOOT ERRORS ====="
journalctl -b -1 -p err --no-pager

echo
echo "===== SSH STATUS ====="
systemctl status ssh --no-pager

echo
echo "===== SSH LOG LAST BOOT ====="
journalctl -u ssh -b -1 --no-pager | tail -100

echo
echo "===== DISK ====="
df -h

echo
echo "===== INODES ====="
df -i

echo
echo "===== MEMORY ====="
free -h

echo
echo "===== OOM KILL CHECK ====="
journalctl -k | grep -Ei "oom|killed process|out of memory" || true

echo
echo "===== SNAPSHOT SCRIPT HISTORY ====="
journalctl --no-pager | grep -Ei "create-live-project|snapshot|rsync|tar|zstd" | tail -100

echo
echo "===== CONFIG SERVICES ====="
systemctl list-units --type=service | grep -Ei "config|location|country|health|fetch"

echo
echo "===== HEALTH SERVICE ====="
systemctl status config-location-health-adaptive.service --no-pager || true

echo
echo "===== MOUNT ====="
mount | column -t

echo
echo "===== FSTAB ====="
cat /etc/fstab

echo
echo "=============================="
echo "REPORT:"
echo "$OUT"
echo "=============================="

