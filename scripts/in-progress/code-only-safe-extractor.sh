#!/bin/bash

set -Eeuo pipefail

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-code-safe-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"


mkdir -p "$WORK" "$REPORT"


echo "================================"
echo " CODE ONLY SAFE EXTRACTOR"
echo "================================"


################################
# CLEAN OLD TEMP
################################

rm -rf /root/config-location-code-safe-*



################################
# DISK CHECK
################################

FREE=$(df -Pm /root | awk 'NR==2 {print $4}')

echo "Free MB: $FREE"

if [ "$FREE" -lt 1000 ]; then
    echo "Not enough disk space"
    exit 1
fi



################################
# SOURCES
################################

SOURCES="
/opt/config-location
/var/lib/config-location
"


mkdir -p "$WORK/source"



################################
# COPY ONLY CODE FILES
################################

echo "[1] Extracting code files"


for SRC in $SOURCES
do

if [ -d "$SRC" ]; then

find "$SRC" \
-type f \
\( \
-name "*.py" \
-o -name "*.sh" \
-o -name "*.js" \
-o -name "*.ts" \
-o -name "*.php" \
-o -name "*.yaml" \
-o -name "*.yml" \
-o -name "*.toml" \
-o -name "*.ini" \
-o -name "*.conf" \
-o -name "*.html" \
-o -name "*.css" \
\) \
-not -path "*/runtime/*" \
-not -path "*/storage/*" \
-not -path "*/raw/*" \
-not -path "*/history/*" \
-not -path "*/results/*" \
-not -path "*/cache/*" \
-not -path "*/queue/*" \
| while read FILE
do

REL="${FILE#/}"

mkdir -p "$WORK/source/$(dirname "$REL")"

cp "$FILE" \
"$WORK/source/$REL"

done

fi

done



################################
# COPY SYSTEM CONFIG
################################

mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
-name "*config*" \
-exec cp {} "$WORK/systemd/" \; \
2>/dev/null || true



################################
# REPORT
################################

echo "[2] Report"


find "$WORK" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/files.txt"


COUNT=$(find "$WORK" -type f | wc -l)

SIZE=$(du -sh "$WORK" | awk '{print $1}')


echo "Files: $COUNT" > "$REPORT/summary.txt"
echo "Size: $SIZE" >> "$REPORT/summary.txt"



if [ "$COUNT" -lt 20 ]; then
    echo "Too few files, stopping"
    exit 1
fi



################################
# COMPRESS
################################

echo "[3] Compress"


tar -cf - \
-C /root \
"$NAME" \
| zstd -15 -T0 -o "$OUT"



sha256sum "$OUT" > "$OUT.sha256"



################################
# CLEAN
################################

rm -rf "$WORK"



echo
echo "DONE"

ls -lh "$OUT"

echo "$OUT"

echo "$OUT.sha256"

echo "$REPORT"

