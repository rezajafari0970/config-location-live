#!/bin/bash

set -Eeuo pipefail

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-real-source-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"


mkdir -p "$WORK"
mkdir -p "$REPORT"


echo "================================="
echo " AUTO REAL SOURCE DISCOVERY"
echo "================================="


####################################
# FIND PROJECT PATHS
####################################

echo "[1] Searching paths"


PATHS=(
"/opt/config-location"
"/var/lib/config-location"
"/srv/config-location"
"/root/config-location"
)


> "$REPORT/path-analysis.txt"


for P in "${PATHS[@]}"
do

if [ -d "$P" ]; then

echo "PATH: $P" >> "$REPORT/path-analysis.txt"

du -sh "$P" >> "$REPORT/path-analysis.txt"


COUNT=$(find "$P" \
-type f \
\( \
-name "*.py" \
-o -name "*.sh" \
-o -name "*.js" \
-o -name "*.php" \
\) | wc -l)


echo "CODE FILES: $COUNT" >> "$REPORT/path-analysis.txt"

echo >> "$REPORT/path-analysis.txt"

fi

done



####################################
# SYSTEMD DISCOVERY
####################################

echo "[2] Systemd discovery"


systemctl cat \
$(systemctl list-units --all \
| grep -Ei "config|location|country|health|fetch" \
| awk '{print $1}') \
> "$REPORT/systemd-discovery.txt" \
2>/dev/null || true



####################################
# SELECT SOURCE
####################################


SOURCE="/var/lib/config-location"


if [ ! -d "$SOURCE" ]; then
SOURCE="/opt/config-location"
fi


echo "Selected source:"
echo "$SOURCE"



####################################
# COPY SOURCE
####################################

mkdir -p "$WORK/project"


echo "[3] Copy"


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
"$SOURCE/" \
"$WORK/project/"



####################################
# VERIFY
####################################

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



cat > "$REPORT/verify.txt" <<INFO

SOURCE:
$SOURCE

SIZE:
${SIZE} MB

FILES:
$FILES

CODE FILES:
$CODE

INFO



if [ "$CODE" -lt 20 ]; then

echo "ERROR: source not complete"
exit 1

fi



####################################
# SERVICES
####################################

mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
-name "*config-location*" \
-exec cp {} "$WORK/systemd/" \; \
2>/dev/null || true



####################################
# DEPENDENCY
####################################

mkdir -p "$WORK/dependencies"


find "$SOURCE" \
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



sha256sum "$OUT" > "$OUT.sha256"



rm -rf "$WORK"



echo
echo "DONE"

ls -lh "$OUT"

echo "$OUT"
echo "$OUT.sha256"

echo "$REPORT"

