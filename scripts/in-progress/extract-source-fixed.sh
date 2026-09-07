#!/bin/bash

set -Eeuo pipefail


BASE="/root/aop"

SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-source-fixed-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"


mkdir -p "$WORK" "$REPORT"


echo "================================="
echo " FIXED SOURCE EXTRACTOR"
echo "================================="



###################################
# INDEX
###################################

echo "[1] Reading archive"


tar -tzf "$SRC" \
> "$REPORT/all-files.txt"



ROOT_PREFIX=$(head -1 "$REPORT/all-files.txt" | cut -d/ -f1)



echo "Detected prefix:"
echo "$ROOT_PREFIX" \
> "$REPORT/prefix.txt"



###################################
# FIND SOURCE
###################################

echo "[2] Detect source files"


grep -E \
'/(app|panel|publish|health|country|parser|fetch|scripts|bin|tests|migrations)/|\.py$|\.sh$|\.js$|\.ts$|\.php$|\.yaml$|\.yml$|requirements|pyproject' \
"$REPORT/all-files.txt" \
| grep -Ev \
'(runtime|storage|raw|history|results|cache|backup|backups|archive)' \
> "$REPORT/source-paths-full.txt"



COUNT=$(wc -l < "$REPORT/source-paths-full.txt")


echo "Detected:"
echo "$COUNT"



if [ "$COUNT" -lt 20 ]; then
    echo "Source detection failed"
    exit 1
fi



###################################
# MAKE RELATIVE LIST
###################################

sed "s#^$ROOT_PREFIX/##" \
"$REPORT/source-paths-full.txt" \
> "$REPORT/source-paths-relative.txt"



###################################
# EXTRACT
###################################

echo "[3] Extract selected files"


mkdir -p "$WORK/project"


tar -xzf "$SRC" \
-C "$WORK/project" \
--strip-components=1 \
--files-from="$REPORT/source-paths-full.txt"



###################################
# COPY SYSTEM FILES
###################################

mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
-name "*config-location*" \
-exec cp {} "$WORK/systemd/" \; \
2>/dev/null || true



###################################
# REPORT
###################################

find "$WORK" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/final-files.txt"


SIZE=$(du -sh "$WORK" | awk '{print $1}')


echo "SIZE:"
echo "$SIZE" \
> "$REPORT/final-size.txt"



###################################
# COMPRESS
###################################

echo "[4] Compress"


tar -cf - \
-C /root \
"$NAME" \
| zstd -15 -T0 -o "$OUT"



sha256sum "$OUT" \
> "$OUT.sha256"



rm -rf "$WORK"



echo
echo "DONE"

ls -lh "$OUT"

echo "$OUT"

echo "$OUT.sha256"

echo "$REPORT"

