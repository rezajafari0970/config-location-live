#!/bin/bash

set -Eeuo pipefail


BASE="/root/aop"

SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-source-final-fixed-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"


mkdir -p "$WORK" "$REPORT"


echo "================================"
echo " FINAL FIXED SOURCE EXTRACT"
echo "================================"



echo "[1] Reading archive"


tar -tzf "$SRC" \
> "$REPORT/archive-list.txt"



echo "[2] Detect source files"



grep -E \
'/(app|panel|publish|health|country|parser|fetch|scripts|bin|tests|migrations)/|\.py$|\.sh$|\.js$|\.ts$|\.php$|\.yaml$|\.yml$|\.toml$|requirements|pyproject' \
"$REPORT/archive-list.txt" \
| grep -Ev \
'(runtime|storage|raw|history|results|cache|backup|backups|archive)' \
> "$REPORT/candidates.txt"



echo "[3] Validate paths"


# فقط فایل‌هایی که واقعاً در tar هستند

while read -r FILE
do

if grep -Fxq "$FILE" "$REPORT/archive-list.txt"
then
    echo "$FILE"
fi

done < "$REPORT/candidates.txt" \
> "$REPORT/valid-files.txt"



COUNT=$(wc -l < "$REPORT/valid-files.txt")


echo "Valid source files: $COUNT"


if [ "$COUNT" -lt 20 ]; then
    echo "Too few files"
    exit 1
fi



echo "[4] Extract"


mkdir -p "$WORK/project"


tar -xzf "$SRC" \
-C "$WORK/project" \
--files-from="$REPORT/valid-files.txt" \
--ignore-failed-read \
|| true



echo "[5] Reports"


find "$WORK" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/extracted-files.txt"



SIZE=$(du -sh "$WORK" | awk '{print $1}')

echo "Final size: $SIZE" \
> "$REPORT/size.txt"



echo "[6] Compress"


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


