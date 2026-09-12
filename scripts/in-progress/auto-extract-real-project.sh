#!/bin/bash

set -Eeuo pipefail

SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-auto-project-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"


mkdir -p "$WORK" "$REPORT"


echo "================================"
echo " AUTO REAL PROJECT EXTRACT"
echo "================================"


echo "[1] Reading archive index"

tar -tzf "$SRC" > "$REPORT/index.txt"



echo "[2] Detect project root"


grep -E \
'/(app|panel|publish|health|country|parser|fetch|scripts|bin)/' \
"$REPORT/index.txt" \
| head -1 \
> "$REPORT/example-path.txt"


ROOT=$(cat "$REPORT/example-path.txt" | cut -d/ -f1-2)


echo "Detected root:"
echo "$ROOT"



echo "[3] Build exact file list"


grep -E \
'/(app|panel|publish|health|country|parser|fetch|scripts|bin|tests)/|requirements|pyproject|setup\.py|\.py$|\.sh$|\.js$|\.ts$|\.php$|\.yaml$|\.yml$|\.toml$' \
"$REPORT/index.txt" \
| grep -Ev \
'(runtime|storage|raw|history|results|cache|backup|archive)' \
> "$REPORT/files.txt"



COUNT=$(wc -l < "$REPORT/files.txt")

echo "Files:"
echo "$COUNT"


if [ "$COUNT" -lt 50 ]; then
    echo "ERROR: project files not detected"
    exit 1
fi



echo "[4] Extract using exact list"


mkdir -p "$WORK/project"


tar -xzf "$SRC" \
-C "$WORK/project" \
-T "$REPORT/files.txt" \
--ignore-failed-read \
2>/dev/null || true



echo "[5] Copy system files"


mkdir -p "$WORK/systemd"

find /etc/systemd/system \
-type f \
-name "*config*" \
-exec cp {} "$WORK/systemd/" \; \
2>/dev/null || true



echo "[6] Nginx"

mkdir -p "$WORK/nginx"

nginx -T \
> "$WORK/nginx/nginx.txt" \
2>&1 || true



echo "[7] Verify"


find "$WORK" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/final-files.txt"



SIZE=$(du -sh "$WORK" | awk '{print $1}')

echo "$SIZE" > "$REPORT/final-size.txt"



echo "[8] Compress"


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

