#!/bin/bash

set -Eeuo pipefail

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-code-only-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"

LOG="$BASE/$NAME.log"


mkdir -p "$WORK" "$REPORT"


exec > >(tee -a "$LOG") 2>&1


echo "================================"
echo " CONFIG LOCATION CODE SNAPSHOT"
echo "================================"


####################################
# CLEAN FAILED TEMP
####################################

rm -rf /root/config-location-code-only-*



####################################
# CHECK DISK
####################################

FREE=$(df -Pm /root | awk 'NR==2 {print $4}')

echo "Free MB: $FREE"


if [ "$FREE" -lt 1000 ]; then
    echo "Not enough free space"
    exit 1
fi



####################################
# COPY OPT SOURCE
####################################

echo "[1] Copy opt source"


mkdir -p "$WORK/project/opt"


if [ -d /opt/config-location ]; then

rsync -aHAX \
--exclude="venv" \
--exclude=".venv" \
--exclude="node_modules" \
--exclude=".git" \
--exclude="__pycache__" \
--exclude="*.pyc" \
--exclude="*.log" \
--exclude="logs" \
--exclude="runtime" \
--exclude="storage" \
--exclude="raw" \
--exclude="state" \
--exclude="cache" \
--exclude="tmp" \
/opt/config-location/ \
"$WORK/project/opt/"

fi



####################################
# COPY ONLY CODE FROM VAR LIB
####################################

echo "[2] Extract code from var"


mkdir -p "$WORK/project/var"


if [ -d /var/lib/config-location ]; then


find /var/lib/config-location \
-type f \
\( \
-name "*.py" \
-o -name "*.sh" \
-o -name "*.js" \
-o -name "*.ts" \
-o -name "*.php" \
-o -name "*.yaml" \
-o -name "*.yml" \
-o -name "*.toml" \
-o -name "*.ini" \
-o -name "*.conf" \
\) \
-not -path "*/history/*" \
-not -path "*/results/*" \
-not -path "*/runtime/*" \
-not -path "*/storage/*" \
-not -path "*/raw/*" \
-not -path "*/cache/*" \
| while read FILE
do

mkdir -p "$WORK/project/var$(dirname "$FILE")"

cp "$FILE" \
"$WORK/project/var$FILE"

done


fi



####################################
# SYSTEMD
####################################

echo "[3] Systemd"


mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
\( \
-name "*config*" \
-o -name "*location*" \
-o -name "*health*" \
-o -name "*fetch*" \
\) \
-exec cp {} "$WORK/systemd/" \; \
2>/dev/null || true



####################################
# NGINX
####################################

echo "[4] nginx"


mkdir -p "$WORK/nginx"


nginx -T \
> "$WORK/nginx/nginx-full.txt" \
2>&1 || true



####################################
# REPORT
####################################

echo "[5] Report"


find "$WORK" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/files.txt"


CODE=$(find "$WORK" \
-type f \
\( \
-name "*.py" \
-o -name "*.sh" \
-o -name "*.js" \
\) | wc -l)


SIZE=$(du -sh "$WORK" | awk '{print $1}')


cat > "$REPORT/summary.txt" <<INFO

Snapshot:
$NAME

Size:
$SIZE

Code files:
$CODE

Created:
$(date)

INFO



if [ "$CODE" -lt 10 ]; then
 echo "ERROR: Not enough code files"
 exit 1
fi



####################################
# COMPRESS
####################################

echo "[6] Compress"


tar -cf - \
-C /root \
"$NAME" \
| zstd -15 -T0 -o "$OUT"



sha256sum "$OUT" \
> "$OUT.sha256"



rm -rf "$WORK"



echo
echo "DONE"

ls -lh "$OUT"

echo "$OUT"

echo "$OUT.sha256"

echo "$REPORT"

