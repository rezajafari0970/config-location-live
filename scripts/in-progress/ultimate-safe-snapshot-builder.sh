#!/bin/bash

set -Eeuo pipefail


SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

OUT="$BASE/config-location-ultimate-$DATE.tar.zst"

REPORT="$BASE/config-location-ultimate-$DATE-report"

LOG="$BASE/config-location-ultimate-$DATE.log"


mkdir -p "$REPORT"


exec > >(tee -a "$LOG") 2>&1


echo "===================================="
echo " ULTIMATE SAFE SNAPSHOT BUILDER"
echo "===================================="


if [ ! -f "$SRC" ]; then
    echo "SOURCE NOT FOUND"
    exit 1
fi



CPU=$(nproc)

echo "CPU:"
echo "$CPU"



echo "[1] Checking source"

ls -lh "$SRC"


echo "[2] Listing archive"


tar -tzf "$SRC" \
> "$REPORT/full-list.txt"



wc -l "$REPORT/full-list.txt"



echo "[3] Create remove report"


grep -E \
'(^|/)(venv|\.venv|node_modules|\.git|__pycache__|logs|backup|backups|archive)/|\.pyc$|\.pyo$|\.log$|\.tar\.gz$|\.tar$|\.zip$|gdrive-SNAPSHOT|snapshot' \
"$REPORT/full-list.txt" \
> "$REPORT/remove-list.txt" || true



echo "[4] Important modules check"


for M in \
app \
panel \
publish \
health \
country \
parser \
storage \
state \
runtime \
configs \
raw \
queues \
remark \
ranking

do

grep -q "/$M/" "$REPORT/full-list.txt" \
&& echo "$M : FOUND" \
|| echo "$M : NOT FOUND"

done \
> "$REPORT/modules.txt"



echo "[5] Build filtered archive"


tar \
-xzf "$SRC" \
--exclude='*/venv/*' \
--exclude='*/.venv/*' \
--exclude='*/node_modules/*' \
--exclude='*/.git/*' \
--exclude='*/__pycache__/*' \
--exclude='*.pyc' \
--exclude='*.pyo' \
--exclude='*.log' \
--exclude='*/logs/*' \
--exclude='*/backup/*' \
--exclude='*/backups/*' \
--exclude='*/archive/*' \
--exclude='*.tar.gz' \
--exclude='*.tar' \
--exclude='*.zip' \
-O \
| zstd -15 -T"$CPU" -o "$OUT"



echo "[6] SHA256"


sha256sum "$OUT" \
> "$OUT.sha256"



echo "[7] Result"


ls -lh "$OUT"

echo "$OUT"
echo "$OUT.sha256"

echo "$REPORT"


