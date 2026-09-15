#!/bin/bash

set -Eeuo pipefail


SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-production-source-clean-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"



mkdir -p "$WORK" "$REPORT"


echo "===================================="
echo " PRODUCTION SOURCE CLEAN SNAPSHOT"
echo "===================================="



####################################
# INDEX
####################################

echo "[1] Reading archive"


tar -tzf "$SRC" > "$REPORT/archive-index.txt"



ROOT=$(head -1 "$REPORT/archive-index.txt" | cut -d/ -f1)


echo "$ROOT" > "$REPORT/root.txt"



####################################
# BUILD EXACT PATH LIST
####################################

echo "[2] Build file list"



cat > "$REPORT/include-list.txt" <<LIST

$ROOT/project
$ROOT/dependencies
$ROOT/PROJECT-ANALYSIS.txt

LIST



grep -E "^$ROOT/(project|dependencies)/" \
"$REPORT/archive-index.txt" \
| grep -Ev \
'/(runtime|runtime-status|reports|history|health-results|storage|raw|cache|backup|backups)/' \
> "$REPORT/extract-list.txt"



COUNT=$(wc -l < "$REPORT/extract-list.txt")


echo "Files:"
echo "$COUNT"



if [ "$COUNT" -lt 100 ]; then
    echo "ERROR: incomplete source"
    exit 1
fi



####################################
# EXTRACT
####################################

echo "[3] Extract source"


mkdir -p "$WORK"



tar -xzf "$SRC" \
-C "$WORK" \
-T "$REPORT/extract-list.txt" \
--ignore-failed-read \
|| true



####################################
# COPY SYSTEMD
####################################

echo "[4] Systemd"


mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
\( \
-name "*config-location*" \
-o -name "*fetch*" \
-o -name "*health*" \
-o -name "*country*" \
\) \
-exec cp {} "$WORK/systemd/" \; \
2>/dev/null || true



####################################
# NGINX
####################################

echo "[5] Nginx"


mkdir -p "$WORK/nginx"


nginx -T \
> "$WORK/nginx/nginx-full.txt" \
2>&1 || true



####################################
# REPORT
####################################


find "$WORK" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/final-files.txt"



SIZE=$(du -sh "$WORK" | awk '{print $1}')


echo "$SIZE" > "$REPORT/final-size.txt"



####################################
# COMPRESS
####################################


echo "[6] Compress"


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


