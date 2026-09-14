#!/bin/bash

set -Eeuo pipefail


SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-real-source-final-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"



mkdir -p "$WORK" "$REPORT"


echo "================================="
echo " REAL SOURCE FINAL BUILDER"
echo "================================="



#################################
# INDEX
#################################

echo "[1] Reading archive"


tar -tzf "$SRC" \
> "$REPORT/archive-list.txt"



PREFIX=$(head -1 "$REPORT/archive-list.txt" | cut -d/ -f1)


echo "$PREFIX" \
> "$REPORT/prefix.txt"



#################################
# SOURCE PATH
#################################

PROJECT_PATH="$PREFIX/project"



echo "[2] Extract project source"


grep "^$PROJECT_PATH/" \
"$REPORT/archive-list.txt" \
| grep -Ev \
'/(runtime|runtime-status|reports|history|health-results|storage|raw|cache|backup|backups|archive)/' \
> "$REPORT/project-files.txt"



COUNT=$(wc -l < "$REPORT/project-files.txt")


echo "Files detected:"
echo "$COUNT"



if [ "$COUNT" -lt 100 ]; then
    echo "ERROR: source detection failed"
    exit 1
fi



#################################
# EXTRACT
#################################

echo "[3] Extract"


mkdir -p "$WORK/project"


tar -xzf "$SRC" \
-C "$WORK" \
--files-from="$REPORT/project-files.txt" \
--ignore-failed-read \
|| true



#################################
# DEPENDENCIES
#################################

echo "[4] Dependencies"


mkdir -p "$WORK/dependencies"


tar -xzf "$SRC" \
-C "$WORK" \
"$PREFIX/dependencies" \
--ignore-failed-read \
2>/dev/null || true



#################################
# SYSTEMD
#################################

echo "[5] Systemd"


mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
-name "*config-location*" \
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
# REPORT
#################################

find "$WORK" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/final-files.txt"



SIZE=$(du -sh "$WORK" | awk '{print $1}')


echo "Final size:"
echo "$SIZE" \
> "$REPORT/final-size.txt"



#################################
# COMPRESS
#################################

echo "[7] Compress"


tar -cf - \
-C /root \
"$NAME" \
| zstd -15 -T0 \
-o "$OUT"



sha256sum "$OUT" \
> "$OUT.sha256"



rm -rf "$WORK"



echo
echo "DONE"

ls -lh "$OUT"

echo "$OUT"

echo "$OUT.sha256"

echo "$REPORT"

