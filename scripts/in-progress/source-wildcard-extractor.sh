#!/bin/bash

set -Eeuo pipefail

SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-source-wildcard-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"


mkdir -p "$WORK" "$REPORT"


echo "================================="
echo " WILDCARD SOURCE EXTRACTOR"
echo "================================="


echo "[1] Reading archive"

tar -tzf "$SRC" > "$REPORT/archive.txt"


PREFIX=$(head -1 "$REPORT/archive.txt" | cut -d/ -f1)

echo "$PREFIX" > "$REPORT/prefix.txt"


echo "[2] Detect patterns"


cat > "$REPORT/patterns.txt" <<PAT

*/app/*
*/panel/*
*/publish/*
*/health/*
*/country/*
*/parser/*
*/fetch*
*/scripts/*
*/bin/*
*.py
*.sh
*.js
*.ts
*.php
*.yaml
*.yml
*.toml
requirements*
pyproject*

PAT



echo "[3] Extract source with wildcard"


mkdir -p "$WORK/project"


tar -xzf "$SRC" \
-C "$WORK/project" \
--wildcards \
--ignore-failed-read \
\
"*/app/*" \
"*/panel/*" \
"*/publish/*" \
"*/health/*" \
"*/country/*" \
"*/parser/*" \
"*/fetch*" \
"*/scripts/*" \
"*/bin/*" \
"*.py" \
"*.sh" \
"*.js" \
"*.ts" \
"*.php" \
"*.yaml" \
"*.yml" \
"*.toml" \
"requirements*" \
"pyproject*" \
2>/dev/null || true



echo "[4] Remove data"


find "$WORK" \
\( \
-path "*/runtime/*" \
-o -path "*/storage/*" \
-o -path "*/raw/*" \
-o -path "*/history/*" \
-o -path "*/results/*" \
-o -path "*/cache/*" \
\) \
-print \
> "$REPORT/removed.txt"


while read -r F
do
    [ -e "$F" ] && rm -rf "$F"
done < "$REPORT/removed.txt"



echo "[5] Verify"


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
    echo "ERROR: too few files"
    exit 1
fi



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

