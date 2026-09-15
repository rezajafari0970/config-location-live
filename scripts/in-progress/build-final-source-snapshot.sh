#!/bin/bash

set -Eeuo pipefail

SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-final-source-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"


mkdir -p "$WORK" "$REPORT"


echo "================================"
echo " FINAL SOURCE SNAPSHOT"
echo "================================"



###################################
# INDEX
###################################

echo "[1] Reading archive"


tar -tzf "$SRC" > "$REPORT/archive-list.txt"



PREFIX=$(head -1 "$REPORT/archive-list.txt" | cut -d/ -f1)

echo "$PREFIX" > "$REPORT/prefix.txt"


echo "PREFIX:"
echo "$PREFIX"



###################################
# BUILD EXACT LIST
###################################

echo "[2] Building source list"


grep "^$PREFIX/project/" \
"$REPORT/archive-list.txt" \
| grep -Ev \
'/(runtime|storage|raw|state|queues|health-results|history|cache|backup|backups|archive)/' \
| grep -E \
'/(app|panel|publish|health|country|parser|fetch|scripts|bin|tests|migrations)/|requirements|pyproject|setup\.py|\.py$|\.sh$|\.js$|\.ts$|\.php$|\.yaml$|\.yml$|\.toml$' \
> "$REPORT/source-list.txt"



COUNT=$(wc -l < "$REPORT/source-list.txt")


echo "SOURCE FILE COUNT:"
echo "$COUNT"



if [ "$COUNT" -lt 50 ]; then
    echo "ERROR: source list too small"
    exit 1
fi



###################################
# EXTRACT
###################################

echo "[3] Extract"


mkdir -p "$WORK/project"


tar -xzf "$SRC" \
-C "$WORK" \
--files-from="$REPORT/source-list.txt" \
--ignore-failed-read \
|| true



###################################
# CLEAN PATH
###################################

echo "[4] Clean"


find "$WORK" \
-type d \
-empty \
-delete 2>/dev/null || true



###################################
# SYSTEMD
###################################

echo "[5] Systemd"


mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
-name "*config-location*" \
-exec cp {} "$WORK/systemd/" \; \
2>/dev/null || true



###################################
# NGINX
###################################

echo "[6] Nginx"


mkdir -p "$WORK/nginx"


nginx -T \
> "$WORK/nginx/nginx-full.txt" \
2>&1 || true



###################################
# REPORT
###################################

find "$WORK" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/final-files.txt"


SIZE=$(du -sh "$WORK" | awk '{print $1}')


echo "FINAL SIZE:"
echo "$SIZE" \
> "$REPORT/final-size.txt"



###################################
# COMPRESS
###################################

echo "[7] Compress"


tar -cf - \
-C /root \
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


