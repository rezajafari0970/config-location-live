#!/bin/bash

OUT="/root/3245/migration-search-report-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$OUT"

echo "===== MIGRATION SEARCH REPORT =====" > "$OUT/info.txt"
date >> "$OUT/info.txt"


echo "[1] migration/schema/version references"

grep -R \
-E "migration|migrate|schema_version|upgrade|version" \
/opt/config-location \
-n \
2>/dev/null \
> "$OUT/grep-result.txt" || true


echo "[2] migration related files"

find /opt/config-location \
-type f \
| grep -Ei "migrat|schema|upgrade|version" \
> "$OUT/file-result.txt" || true


echo "[3] directories"

find /opt/config-location \
-type d \
| grep -Ei "migrat|schema|upgrade" \
> "$OUT/directory-result.txt" || true


echo "DONE"

tar -cf - \
-C /root/3245 \
"$(basename "$OUT")" \
| zstd -10 -T0 \
-o "${OUT}.tar.zst"


sha256sum "${OUT}.tar.zst" \
> "${OUT}.tar.zst.sha256"


echo "${OUT}.tar.zst"
echo "${OUT}.tar.zst.sha256"

