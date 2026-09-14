#!/bin/bash

set -Eeuo pipefail

SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-final-real-project-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"


mkdir -p "$WORK" "$REPORT"


echo "[1] Index"

tar -tzf "$SRC" > "$REPORT/index.txt"


echo "[2] Extract real folders"


tar -xzf "$SRC" \
-C "$WORK" \
--wildcards \
--ignore-failed-read \
"*/project/app/*" \
"*/project/tests/*" \
"*/project/scripts/*" \
"*/project/bin/*" \
"*/dependencies/*" \
"*/PROJECT-ANALYSIS.txt" \
2>/dev/null || true



echo "[3] Remove data"


find "$WORK" \
-type d \
\( \
-name runtime \
-o -name reports \
-o -name history \
-o -name storage \
-o -name raw \
-o -name cache \
\) \
-prune \
-exec rm -rf {} + \
2>/dev/null || true



echo "[4] Report"


find "$WORK" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/files.txt"


COUNT=$(wc -l < "$REPORT/files.txt")

SIZE=$(du -sh "$WORK" | awk '{print $1}')


echo "FILES=$COUNT" > "$REPORT/summary.txt"
echo "SIZE=$SIZE" >> "$REPORT/summary.txt"



echo "[5] Compress"


tar -cf - \
-C /root \
"$NAME" \
| zstd -15 -T0 -o "$OUT"



sha256sum "$OUT" > "$OUT.sha256"


rm -rf "$WORK"


echo DONE

ls -lh "$OUT"

