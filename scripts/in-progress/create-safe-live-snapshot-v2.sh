#!/bin/bash

set -Eeuo pipefail

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-safe-live-v2-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"

PROJECT="/opt/config-location"


mkdir -p "$WORK" "$REPORT"


echo "=============================="
echo " SAFE LIVE SNAPSHOT V2"
echo "=============================="


echo "[1] System info"

{
echo "DATE:"
date

echo
echo "HOST:"
hostname

echo
echo "DISK:"
df -h

echo
echo "MEMORY:"
free -h

} > "$REPORT/system.txt"



echo "[2] Copy project live"


mkdir -p "$WORK/project"


rsync -aHAX \
--numeric-ids \
--info=progress2 \
--exclude="venv" \
--exclude=".venv" \
--exclude="node_modules" \
--exclude=".git" \
--exclude="__pycache__" \
--exclude="*.pyc" \
--exclude="*.pyo" \
--exclude="*.log" \
--exclude="logs" \
--exclude="backup" \
--exclude="backups" \
--exclude="*.tar.gz" \
--exclude="*.zip" \
"$PROJECT/" \
"$WORK/project/" \
> "$REPORT/rsync.log" 2>&1



echo "[3] Systemd"


mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
-name "*.service" \
| grep -Ei "config|location|country|health|fetch|supervisor" \
| while read F
do
cp "$F" "$WORK/systemd/" || true
done



echo "[4] Nginx"


mkdir -p "$WORK/nginx"

nginx -T \
> "$WORK/nginx/nginx-full.txt" \
2>&1 || true



echo "[5] Dependencies"


mkdir -p "$WORK/dependencies"


find "$PROJECT" \
-type f \
\( \
-name "requirements*.txt" \
-o -name "pyproject.toml" \
-o -name "setup.py" \
-o -name "package.json" \
\) \
-exec cp --parents {} "$WORK/dependencies/" \; \
2>/dev/null || true



echo "[6] Report"


find "$WORK" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/files.txt"


find "$WORK/project" \
-type f \
| wc -l \
> "$REPORT/file-count.txt"


du -h --max-depth=2 "$WORK" \
> "$REPORT/size-map.txt"



echo "[7] Compress"


tar -cf - \
-C /root \
"$NAME" \
| zstd -15 -T0 -o "$OUT"



sha256sum "$OUT" > "$OUT.sha256"



rm -rf "$WORK"



echo
echo "DONE"

ls -lh "$OUT"

echo "$OUT"
echo "$OUT.sha256"
echo "$REPORT"

