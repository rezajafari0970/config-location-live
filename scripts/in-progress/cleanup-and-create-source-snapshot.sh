#!/bin/bash

set -Eeuo pipefail


BASE="/root/aop"

SOURCE="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

PROJECT="/opt/config-location"


DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-source-only-$DATE"

WORK="/root/aop/work-$DATE"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"



echo "================================="
echo " CLEANUP + SOURCE SNAPSHOT"
echo "================================="


#################################
# CLEAN OLD SNAPSHOTS
#################################

echo "[1] Cleaning old files"


find "$BASE" \
-maxdepth 1 \
-type d \
-name "convert-work" \
-exec rm -rf {} \;


find "$BASE" \
-maxdepth 1 \
-type d \
-name "pre-production-backup*" \
-exec rm -rf {} \;


find "$BASE" \
-maxdepth 1 \
-type f \
-name "*.tar.zst" \
-delete


find "$BASE" \
-maxdepth 1 \
-type f \
-name "*.sha256" \
-delete


find "$BASE" \
-maxdepth 1 \
-type f \
-name "*.log" \
-delete



#################################
# CHECK SPACE
#################################

echo "[2] Disk"

df -h



#################################
# PREPARE
#################################

mkdir -p "$WORK"
mkdir -p "$REPORT"



#################################
# COPY SOURCE
#################################

echo "[3] Copy project"


rsync -aHAX \
--exclude="venv" \
--exclude=".venv" \
--exclude="node_modules" \
--exclude=".git" \
--exclude="__pycache__" \
--exclude="*.pyc" \
--exclude="*.pyo" \
--exclude="*.log" \
--exclude="logs" \
--exclude="backup" \
--exclude="backups" \
--exclude="archive" \
--exclude="*.tar.gz" \
--exclude="*.tar" \
--exclude="*.zip" \
"$PROJECT/" \
"$WORK/project/"



#################################
# REPORT
#################################

find "$WORK/project" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/files.txt"


du -sh "$WORK/project" \
> "$REPORT/size.txt"



#################################
# SYSTEMD
#################################

mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
-name "*config-location*" \
-exec cp {} "$WORK/systemd/" \; \
2>/dev/null || true



#################################
# NGINX
#################################

mkdir -p "$WORK/nginx"


grep -Ril \
"config-location\|4040\|panel\|sub" \
/etc/nginx \
2>/dev/null \
| while read F
do
cp --parents "$F" "$WORK/nginx/" 2>/dev/null || true
done



#################################
# DEPENDENCY
#################################

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
# COMPRESS
#################################

echo "[4] Compress"


tar -cf - \
-C "$(dirname "$WORK")" \
"$(basename "$WORK")" \
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
echo "DONE"

ls -lh "$OUT"

echo "$OUT"
echo "$OUT.sha256"

