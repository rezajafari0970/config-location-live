#!/bin/bash

INDEX="/root/aop/config-location-auto-project-"*/index.txt

OUT="/root/aop/real-tree-report-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$OUT"

FILE=$(ls $INDEX | tail -1)

echo "INDEX:"
echo "$FILE"


echo "[ROOT]"
awk -F/ '{print $1}' "$FILE" | sort -u > "$OUT/root.txt"


echo "[LEVEL2]"
awk -F/ '{print $1"/"$2}' "$FILE" | sort -u > "$OUT/level2.txt"


echo "[LEVEL3]"
awk -F/ '{print $1"/"$2"/"$3}' "$FILE" | sort -u > "$OUT/level3.txt"


echo "[ALL PROJECT LIKE]"
grep -Ei "app|panel|parser|fetch|health|country|publish|worker|script|bin" \
"$FILE" \
| head -200 \
> "$OUT/project-candidates.txt"


echo "[CODE COUNT]"
grep -Ei "\.(py|sh|js|ts|php|yaml|yml|toml)$" \
"$FILE" \
| wc -l \
> "$OUT/code-count.txt"


echo
echo "DONE"
echo "$OUT"

