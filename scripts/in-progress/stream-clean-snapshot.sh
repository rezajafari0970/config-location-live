#!/bin/bash

set -Eeuo pipefail

SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

OUT="$BASE/config-location-clean-$DATE.tar.zst"

REPORT="$BASE/config-location-clean-$DATE-report"

LOCK="/tmp/config-location-stream.lock"


mkdir -p "$REPORT"


if [ -e "$LOCK" ]; then
    echo "Another job running"
    exit 1
fi

touch "$LOCK"

trap 'rm -f "$LOCK"' EXIT


echo "================================="
echo " STREAM CLEAN SNAPSHOT"
echo "================================="


if [ ! -f "$SRC" ]; then
    echo "Source not found"
    exit 1
fi


CPU=$(nproc)

echo "CPU: $CPU"


echo "[1] Reading archive list"


tar -tzf "$SRC" \
> "$REPORT/all-files.txt"



echo "[2] Building keep list"


grep -Ev \
'(^|/)(venv|\.venv|node_modules|\.git|__pycache__|logs|backup|backups|archive)/|\.pyc$|\.pyo$|\.log$|\.tar\.gz$|\.tar$|\.zip$|gdrive-SNAPSHOT|snapshot' \
"$REPORT/all-files.txt" \
> "$REPORT/keep-files.txt"



echo "[3] Removed list"


LC_ALL=C comm -23 \
<(LC_ALL=C sort "$REPORT/all-files.txt") \
<(LC_ALL=C sort "$REPORT/keep-files.txt") \
> "$REPORT/removed-files.txt"



KEEP_COUNT=$(wc -l < "$REPORT/keep-files.txt")

REMOVE_COUNT=$(wc -l < "$REPORT/removed-files.txt")


echo "Keep: $KEEP_COUNT"
echo "Remove: $REMOVE_COUNT"



echo "[4] Creating filtered tar.zst"


tar -xzf "$SRC" \
--to-stdout \
--files-from="$REPORT/keep-files.txt" \
2>/dev/null \
| zstd -15 -T"$CPU" -o "$OUT"



echo "[5] SHA256"


sha256sum "$OUT" \
> "$OUT.sha256"



echo "[6] Result"


ls -lh "$OUT"

echo
echo "REPORT:"
echo "$REPORT"

echo
echo "DONE"


