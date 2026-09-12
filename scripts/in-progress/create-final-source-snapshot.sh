#!/bin/bash

set -Eeuo pipefail

BASE="/root/aop"
DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-final-source-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"


mkdir -p "$WORK" "$REPORT"


echo "===== FINAL SOURCE SNAPSHOT ====="


echo "[1] Copy project"


mkdir -p "$WORK/opt"


rsync -aHAX \
--numeric-ids \
--exclude="venv" \
--exclude="backups" \
--exclude="*.log" \
--exclude="__pycache__" \
--exclude="*.pyc" \
/opt/config-location/ \
"$WORK/opt/config-location/"



echo "[2] Runtime data"


mkdir -p "$WORK/var/lib"


rsync -aHAX \
--numeric-ids \
/var/lib/config-location/ \
"$WORK/var/lib/config-location/" \
2>/dev/null || true



echo "[3] Config"


mkdir -p "$WORK/etc"


rsync -aHAX \
/etc/config-location/ \
"$WORK/etc/config-location/" \
2>/dev/null || true



echo "[4] Systemd"


mkdir -p "$WORK/systemd"


cp /etc/systemd/system/config-location* \
"$WORK/systemd/" \
2>/dev/null || true



echo "[5] Report"


du -h --max-depth=3 "$WORK" \
> "$REPORT/size-map.txt"


find "$WORK" -type f \
| wc -l \
> "$REPORT/file-count.txt"


find "$WORK" -type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/files.txt"



echo "[6] Compress"


tar -cf - \
-C /root \
"$NAME" \
| zstd -15 -T0 -o "$OUT"


sha256sum "$OUT" > "$OUT.sha256"


rm -rf "$WORK"


echo DONE

ls -lh "$OUT"

