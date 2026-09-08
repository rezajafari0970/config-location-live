#!/bin/bash

set -Eeuo pipefail

SRC="/opt/config-location"
BASE="/root/3245"

OUT="$BASE/full-source-code-review-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$OUT"

echo "FULL SOURCE CODE REVIEW" > "$OUT/info.txt"
date >> "$OUT/info.txt"


echo "[1] FILE LIST"

find "$SRC" \
-type f \
\( \
-name "*.py" \
-o -name "*.sh" \
-o -name "*.service" \
-o -name "*.json" \
-o -name "*.yaml" \
-o -name "*.yml" \
\) \
-not -path "*/venv/*" \
-not -path "*/__pycache__/*" \
| sort > "$OUT/file-list.txt"



echo "[2] FULL SOURCE"

while read -r FILE
do
    echo "========================================" >> "$OUT/source.txt"
    echo "FILE: $FILE" >> "$OUT/source.txt"
    echo "========================================" >> "$OUT/source.txt"
    cat "$FILE" >> "$OUT/source.txt"
    echo >> "$OUT/source.txt"
done < "$OUT/file-list.txt"



echo "[3] ALL FILES"

find "$SRC" \
-type f \
-not -path "*/venv/*" \
-not -path "*/__pycache__/*" \
| sort > "$OUT/all-files.txt"



echo "[4] PACK"

tar -cf - \
-C "$BASE" \
"$(basename "$OUT")" \
| zstd -15 -T0 \
-o "$OUT.tar.zst"



sha256sum "$OUT.tar.zst" > "$OUT.tar.zst.sha256"


echo "DONE"
echo "$OUT.tar.zst"
echo "$OUT.tar.zst.sha256"

