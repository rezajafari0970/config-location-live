#!/bin/bash

set -Eeuo pipefail

SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-final-correct-source-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"

mkdir -p "$WORK" "$REPORT"


echo "[1] Index"

tar -tzf "$SRC" > "$REPORT/index.txt"


echo "[2] Find real project paths"


grep -E \
'/(project|dependencies)/' \
"$REPORT/index.txt" \
| grep -Ev \
'(runtime|runtime-status|reports|history|health-results|storage|raw|cache|backup)' \
> "$REPORT/files.txt"


COUNT=$(wc -l < "$REPORT/files.txt")

echo "FILES=$COUNT"


if [ "$COUNT" -lt 50 ]; then
    echo "BAD LIST"
    exit 1
fi


echo "[3] Extract"


tar -xzf "$SRC" \
-C "$WORK" \
-T "$REPORT/files.txt" \
--ignore-failed-read \
2>/dev/null || true



echo "[4] Remove empty dirs"

find "$WORK" -type d -empty -delete || true


echo "[5] Report"

find "$WORK" -type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/files-final.txt"



SIZE=$(du -sh "$WORK" | awk '{print $1}')

echo "$SIZE" > "$REPORT/size.txt"



echo "[6] Compress"


tar -cf - \
-C /root \
"$NAME" \
| zstd -15 -T0 -o "$OUT"



sha256sum "$OUT" > "$OUT.sha256"


rm -rf "$WORK"


echo DONE

ls -lh "$OUT"

