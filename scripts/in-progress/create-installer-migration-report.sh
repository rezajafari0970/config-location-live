#!/bin/bash

set -e

SRC="/root/source-review/config-location"

OUT="/root/installer-migration-report-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$OUT"

echo "===== INSTALLER + MIGRATION FULL REPORT =====" > "$OUT/README.txt"

echo "" >> "$OUT/README.txt"
echo "DATE:" >> "$OUT/README.txt"
date >> "$OUT/README.txt"


################################
# STRUCTURE
################################

echo "[1] Structure"

find "$SRC" \
\( \
-path "$SRC/installer/*" \
-o -path "$SRC/migrations/*" \
-o -name "install-oneclick.sh" \
\) \
-type f \
| sort \
> "$OUT/file-list.txt"



################################
# SIZE
################################

echo "[2] Size"

while read -r F
do
    du -h "$F"
done < "$OUT/file-list.txt" \
> "$OUT/file-size.txt"



################################
# CONTENT
################################

echo "[3] Content"


while read -r F
do

echo "==================================================" >> "$OUT/full-content.txt"

echo "FILE:" >> "$OUT/full-content.txt"

echo "$F" >> "$OUT/full-content.txt"

echo "==================================================" >> "$OUT/full-content.txt"

sed -n '1,400p' "$F" >> "$OUT/full-content.txt"

echo "" >> "$OUT/full-content.txt"

done < "$OUT/file-list.txt"



################################
# INSTALLER ONLY
################################

mkdir -p "$OUT/installer"

if [ -d "$SRC/installer" ]; then

cp -r "$SRC/installer/"* \
"$OUT/installer/" \
2>/dev/null || true

fi


################################
# MIGRATION ONLY
################################

mkdir -p "$OUT/migrations"

if [ -d "$SRC/migrations" ]; then

cp -r "$SRC/migrations/"* \
"$OUT/migrations/" \
2>/dev/null || true

fi


################################
# COMPRESS
################################

tar -cf - \
-C /root \
"$(basename "$OUT")" \
| zstd -10 -T0 \
-o "${OUT}.tar.zst"


sha256sum "${OUT}.tar.zst" \
> "${OUT}.tar.zst.sha256"


echo "DONE"

echo "${OUT}.tar.zst"

