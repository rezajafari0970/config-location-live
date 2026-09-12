#!/bin/bash

set -Eeuo pipefail


BASE="/root/aop"

PROJECT="/opt/config-location"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-source-final-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"



echo "======================================"
echo " FINAL CLEAN SOURCE SNAPSHOT"
echo "======================================"



#################################
# CLEAN OLD FAILED BUILDS
#################################

echo "[1] Cleaning old snapshots"


rm -rf /root/aop/config-location-production-audit-20260904-021830
rm -rf /root/aop/config-location-code-only-*
rm -rf /root/aop/config-location-stable-source-*
rm -rf /root/aop/config-location-real-source-*
rm -rf /root/aop/config-location-source-final-*
rm -rf /root/aop/config-location-source-discovered-*
rm -rf /root/aop/config-location-final-*
rm -rf /root/aop/config-location-clean-*
rm -rf /root/config-location-*



#################################
# DISK CHECK
#################################

echo "[2] Disk status"

df -h



FREE=$(df -Pm /root | awk 'NR==2 {print $4}')

if [ "$FREE" -lt 1000 ]; then
    echo "Not enough space"
    exit 1
fi



#################################
# PREPARE
#################################

mkdir -p "$WORK"
mkdir -p "$REPORT"



#################################
# COPY SOURCE
#################################

echo "[3] Copy source"



mkdir -p "$WORK/project"



rsync -aHAX \
--numeric-ids \
--exclude="venv" \
--exclude=".venv" \
--exclude="node_modules" \
--exclude=".git" \
--exclude="__pycache__" \
--exclude="*.pyc" \
--exclude="*.pyo" \
--exclude="*.log" \
--exclude="logs" \
--exclude="runtime" \
--exclude="storage" \
--exclude="raw" \
--exclude="state" \
--exclude="cache" \
--exclude="tmp" \
--exclude="backup" \
--exclude="backups" \
"$PROJECT/" \
"$WORK/project/"



#################################
# VERIFY
#################################

echo "[4] Verify"


SIZE=$(du -sm "$WORK/project" | awk '{print $1}')

FILES=$(find "$WORK/project" -type f | wc -l)

CODE=$(find "$WORK/project" \
-type f \
\( \
-name "*.py" \
-o -name "*.sh" \
-o -name "*.js" \
-o -name "*.php" \
\) | wc -l)



cat > "$REPORT/summary.txt" <<INFO

PROJECT:
/opt/config-location

SIZE:
${SIZE} MB

FILES:
$FILES

CODE FILES:
$CODE

DATE:
$(date)

INFO



if [ "$CODE" -lt 10 ]; then

echo "ERROR: source too small"
exit 1

fi



#################################
# SYSTEMD
#################################

echo "[5] Systemd"


mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
\( \
-name "*config-location*" \
-o -name "*health*" \
-o -name "*country*" \
-o -name "*fetch*" \
\) \
-exec cp {} "$WORK/systemd/" \; \
2>/dev/null || true



#################################
# NGINX
#################################

echo "[6] Nginx"


mkdir -p "$WORK/nginx"


nginx -T \
> "$WORK/nginx/nginx-full.txt" \
2>&1 || true



#################################
# DEPENDENCY
#################################

echo "[7] Dependencies"


mkdir -p "$WORK/dependencies"


find "$PROJECT" \
-type f \
\( \
-name "requirements*.txt" \
-o -name "pyproject.toml" \
-o -name "setup.py" \
\) \
-exec cp --parents {} "$WORK/dependencies/" \; \
2>/dev/null || true



#################################
# REPORT FILE LIST
#################################

find "$WORK" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/files.txt"



#################################
# COMPRESS
#################################

echo "[8] Compress"


tar -cf - \
-C /root \
"$NAME" \
| zstd -15 -T0 -o "$OUT"



#################################
# SHA256
#################################

sha256sum "$OUT" \
> "$OUT.sha256"



#################################
# CLEAN TEMP
#################################

rm -rf "$WORK"



echo
echo "================================"
echo " DONE"
echo "================================"


ls -lh "$OUT"

echo "$OUT"

echo "$OUT.sha256"

echo "$REPORT"


