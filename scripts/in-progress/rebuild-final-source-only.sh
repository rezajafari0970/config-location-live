#!/bin/bash

set -Eeuo pipefail


PROJECT="/opt/config-location"

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-source-final-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"



echo "===================================="
echo " FINAL SOURCE ONLY BUILDER"
echo "===================================="


mkdir -p "$BASE"



####################################
# CLEAN OLD TEST OUTPUTS
####################################

echo "[1] Cleaning old test snapshots"


find "$BASE" \
-maxdepth 1 \
-type d \
\( \
-name "work-*" \
-o -name "convert-work" \
-o -name "config-location-aop-*" \
-o -name "config-location-clean-*" \
-o -name "config-location-final-*" \
-o -name "config-location-source-only-*" \
-o -name "config-location-ultimate-*" \
\) \
-exec rm -rf {} +


find "$BASE" \
-maxdepth 1 \
-type f \
\( \
-name "*.tar.zst" \
-o -name "*.sha256" \
-o -name "*.log" \
\) \
-delete



####################################
# CREATE WORK
####################################

mkdir -p "$WORK/project"
mkdir -p "$REPORT"



####################################
# COPY REAL SOURCE
####################################

echo "[2] Copy source"


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
--exclude="backup" \
--exclude="backups" \
--exclude="archive" \
--exclude="*.tar.gz" \
--exclude="*.tar" \
--exclude="*.zip" \
"$PROJECT/" \
"$WORK/project/"



####################################
# VERIFY
####################################

echo "[3] Verify"


SIZE=$(du -sm "$WORK/project" | awk '{print $1}')

echo "Source size: ${SIZE}MB"


if [ "$SIZE" -lt 1 ]; then

echo "ERROR: Source snapshot is too small"
exit 1

fi



find "$WORK/project" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/files.txt"



####################################
# MODULE CHECK
####################################


for M in \
app \
panel \
publish \
health \
country \
parser \
storage \
state \
runtime \
configs \
raw \
queues \
remark \
ranking

do

if [ -e "$WORK/project/$M" ]
then
echo "$M : OK"
else
echo "$M : MISSING"
fi

done > "$REPORT/modules.txt"



####################################
# SYSTEMD
####################################

mkdir -p "$WORK/systemd"

find /etc/systemd/system \
-type f \
-name "*config-location*" \
-exec cp {} "$WORK/systemd/" \; \
2>/dev/null || true



####################################
# NGINX
####################################

mkdir -p "$WORK/nginx"


grep -Ril \
"config-location\|4040\|panel\|sub" \
/etc/nginx \
2>/dev/null \
| while read F
do
cp --parents "$F" "$WORK/nginx/" 2>/dev/null || true
done



####################################
# DEPENDENCY
####################################

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



####################################
# COMPRESS
####################################

echo "[4] Compress"


tar -cf - \
-C "/root" \
"$NAME" \
| zstd -15 -T0 -o "$OUT"



####################################
# HASH
####################################

sha256sum "$OUT" > "$OUT.sha256"



####################################
# REMOVE TEMP
####################################

rm -rf "$WORK"


echo
echo "DONE"

ls -lh "$OUT"

echo "$OUT"
echo "$OUT.sha256"

echo "$REPORT"

