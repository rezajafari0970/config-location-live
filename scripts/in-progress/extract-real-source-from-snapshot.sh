#!/bin/bash

set -Eeuo pipefail


BASE="/root/aop"

SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"


DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-real-source-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"



mkdir -p "$WORK"
mkdir -p "$REPORT"



echo "===================================="
echo " EXTRACT REAL SOURCE FROM SNAPSHOT"
echo "===================================="



#####################################
# CHECK
#####################################

if [ ! -f "$SRC" ]; then
    echo "Snapshot not found"
    exit 1
fi



#####################################
# LIST CONTENT
#####################################

echo "[1] Reading snapshot index"


tar -tzf "$SRC" \
> "$REPORT/all-files.txt"



#####################################
# FIND SOURCE FILES
#####################################

echo "[2] Finding source files"


grep -E \
'(^|/)(app|panel|publish|health|country|parser|fetch|scripts|bin|tests|migrations)/|\.py$|\.sh$|\.js$|\.ts$|\.php$|\.yaml$|\.yml$|\.toml$|requirements|pyproject' \
"$REPORT/all-files.txt" \
| grep -Ev \
'(runtime|storage|raw|history|results|cache|backup|backups|archive)' \
> "$REPORT/source-files.txt"



COUNT=$(wc -l < "$REPORT/source-files.txt")


echo "Source files:"
echo "$COUNT"



if [ "$COUNT" -lt 20 ]; then
    echo "Source detection failed"
    exit 1
fi



#####################################
# EXTRACT SELECTED FILES
#####################################

echo "[3] Extract source"


tar -xzf "$SRC" \
-C "$WORK" \
--files-from="$REPORT/source-files.txt"



#####################################
# SYSTEMD
#####################################

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



#####################################
# NGINX
#####################################

mkdir -p "$WORK/nginx"


nginx -T \
> "$WORK/nginx/nginx.txt" \
2>&1 || true



#####################################
# REPORT
#####################################

find "$WORK" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/final-files.txt"


SIZE=$(du -sh "$WORK" | awk '{print $1}')


echo "Final size:"
echo "$SIZE" \
> "$REPORT/final-size.txt"



#####################################
# COMPRESS
#####################################

echo "[4] Compress"


tar -cf - \
-C /root \
"$NAME" \
| zstd -15 -T0 -o "$OUT"



sha256sum "$OUT" \
> "$OUT.sha256"



#####################################
# CLEAN
#####################################

rm -rf "$WORK"



echo
echo "DONE"

ls -lh "$OUT"

echo "$OUT"

echo "$OUT.sha256"

echo "$REPORT"


