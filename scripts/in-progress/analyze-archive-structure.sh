#!/bin/bash

set -Eeuo pipefail


SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

OUT="/root/aop/archive-structure-analysis-$(date +%Y%m%d-%H%M%S)"


mkdir -p "$OUT"


echo "================================"
echo " ARCHIVE STRUCTURE ANALYSIS"
echo "================================"


if [ ! -f "$SRC" ]; then
    echo "Archive not found"
    exit 1
fi



echo "[1] Full index"


tar -tzf "$SRC" \
> "$OUT/all-files.txt"



echo "[2] Root folders"


awk -F/ '{print $1}' \
"$OUT/all-files.txt" \
| sort -u \
> "$OUT/root-folders.txt"



echo "[3] First levels"


awk -F/ '{print $1"/"$2}' \
"$OUT/all-files.txt" \
| sort -u \
> "$OUT/second-level.txt"



echo "[4] Project tree"


grep "/project/" \
"$OUT/all-files.txt" \
| awk -F/ '{print $1"/"$2"/"$3"/"$4}' \
| sort -u \
> "$OUT/project-tree.txt"



echo "[5] Code files"


grep -E \
'\.(py|sh|js|ts|php|yaml|yml|toml|ini|conf)$' \
"$OUT/all-files.txt" \
> "$OUT/code-files.txt"



wc -l "$OUT/code-files.txt" \
> "$OUT/code-count.txt"



echo "[6] Modules"


grep -E \
'/(app|panel|publish|health|country|parser|fetch|scripts|bin|tests)/' \
"$OUT/all-files.txt" \
| awk -F/ '{print $1"/"$2"/"$3}' \
| sort -u \
> "$OUT/modules.txt"



echo "[7] Size info"


du -sh "$OUT" \
> "$OUT/analysis-size.txt"



echo
echo "DONE"
echo "$OUT"

