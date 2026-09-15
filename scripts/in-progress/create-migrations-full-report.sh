#!/bin/bash

set -Eeuo pipefail

SRC="/opt/config-location/migrations"

OUT="/root/migrations-full-report-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$OUT"


echo "===== MIGRATIONS FULL REPORT =====" > "$OUT/README.txt"

echo "DATE:" >> "$OUT/README.txt"
date >> "$OUT/README.txt"


echo "[1] FILE LIST"

find "$SRC" \
-type f \
| sort \
> "$OUT/file-list.txt"


echo "[2] FILE SIZE"

while read -r FILE
do
    du -h "$FILE"
done < "$OUT/file-list.txt" \
> "$OUT/file-size.txt"



echo "[3] FULL CONTENT"


while read -r FILE
do

echo "==================================================" >> "$OUT/full-content.txt"

echo "FILE:" >> "$OUT/full-content.txt"

echo "$FILE" >> "$OUT/full-content.txt"

echo "==================================================" >> "$OUT/full-content.txt"

sed -n '1,500p' "$FILE" >> "$OUT/full-content.txt"

echo >> "$OUT/full-content.txt"

done < "$OUT/file-list.txt"



echo "[4] TREE"

find "$SRC" \
| sort \
> "$OUT/tree.txt"



echo "[5] PACK"


tar \
-cf - \
-C /root \
"$(basename "$OUT")" \
| zstd -10 -T0 \
-o "${OUT}.tar.zst"


sha256sum "${OUT}.tar.zst" \
> "${OUT}.tar.zst.sha256"


echo
echo "DONE"

echo "${OUT}.tar.zst"

echo "${OUT}.tar.zst.sha256"

