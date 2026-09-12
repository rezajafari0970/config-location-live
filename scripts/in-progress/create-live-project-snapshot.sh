#!/bin/bash

set -Eeuo pipefail

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-live-snapshot-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"


PROJECT="/opt/config-location"


mkdir -p "$WORK" "$REPORT"


echo "================================"
echo " LIVE PROJECT SNAPSHOT"
echo "================================"


#################################
# SAVE SERVICE STATE
#################################

echo "[1] Save services"


systemctl list-units --all \
| grep -Ei "config|location|country|health|fetch" \
> "$REPORT/services-before.txt" || true


SERVICES=$(awk '{print $1}' "$REPORT/services-before.txt" | grep service || true)


echo "$SERVICES" > "$REPORT/service-list.txt"



#################################
# STOP SERVICES
#################################

echo "[2] Stop services"


for S in $SERVICES
do
    systemctl stop "$S" 2>/dev/null || true
done


sleep 3



#################################
# COPY PROJECT
#################################

echo "[3] Copy project"


mkdir -p "$WORK/project"


rsync -aHAX \
--numeric-ids \
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
--exclude="*.tar" \
--exclude="*.zip" \
"$PROJECT/" \
"$WORK/project/"



#################################
# SYSTEMD
#################################

echo "[4] Systemd"


mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
-name "*.service" \
-o -name "*.timer" \
| grep -Ei "config|location|country|health|fetch" \
| while read F
do
    cp "$F" "$WORK/systemd/" 2>/dev/null || true
done



#################################
# NGINX
#################################

echo "[5] Nginx"


mkdir -p "$WORK/nginx"


nginx -T \
> "$WORK/nginx/nginx-full.txt" \
2>&1 || true



#################################
# DEPENDENCIES
#################################

echo "[6] Dependencies"


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



#################################
# REPORT
#################################

echo "[7] Report"


du -h --max-depth=2 "$WORK" \
> "$REPORT/size-map.txt"


find "$WORK" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/files.txt"


find "$WORK/project" \
-type f \
| wc -l \
> "$REPORT/file-count.txt"



#################################
# COMPRESS
#################################

echo "[8] Compress"


tar -cf - \
-C /root \
"$NAME" \
| zstd -15 -T0 -o "$OUT"



sha256sum "$OUT" > "$OUT.sha256"



#################################
# CLEAN TEMP
#################################

rm -rf "$WORK"



#################################
# START SERVICES
#################################

echo "[9] Start services"


for S in $SERVICES
do
    systemctl start "$S" 2>/dev/null || true
done



echo
echo "DONE"

ls -lh "$OUT"

echo "$OUT"

echo "$OUT.sha256"

echo "$REPORT"

