#!/bin/bash

set -Eeuo pipefail

BASE="/root/aop"

SOURCE="/var/lib/config-location"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-stable-source-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"


mkdir -p "$WORK"
mkdir -p "$REPORT"


echo "================================"
echo " STABLE SOURCE SNAPSHOT"
echo "================================"


#################################
# SAVE SERVICES STATE
#################################

echo "[1] Save services state"


systemctl list-units --all \
| grep -Ei "config|location|country|health|fetch" \
> "$REPORT/services-before.txt" || true


SERVICES=$(cat "$REPORT/services-before.txt" \
| awk '{print $1}' \
| grep '\.service' || true)


echo "$SERVICES" \
> "$REPORT/service-list.txt"



#################################
# STOP SERVICES
#################################

echo "[2] Stop project services"


for S in $SERVICES
do
    systemctl stop "$S" 2>/dev/null || true
done



sleep 3



#################################
# COPY SOURCE
#################################

echo "[3] Copy source"


mkdir -p "$WORK/project"


rsync -aHAX \
--numeric-ids \
--exclude="runtime" \
--exclude="raw" \
--exclude="storage" \
--exclude="state" \
--exclude="queues" \
--exclude="health-results" \
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
"$SOURCE/" \
"$WORK/project/"



#################################
# VERIFY
#################################

echo "[4] Verify"


SIZE=$(du -sm "$WORK/project" | awk '{print $1}')

FILES=$(find "$WORK/project" -type f | wc -l)

CODE=$(find "$WORK/project" \
-type f \
\( \
-name "*.py" \
-o -name "*.sh" \
-o -name "*.js" \
-o -name "*.php" \
\) | wc -l)


cat > "$REPORT/verify.txt" <<INFO

SOURCE:
$SOURCE

SIZE:
${SIZE} MB

FILES:
$FILES

CODE FILES:
$CODE

INFO



if [ "$CODE" -lt 20 ]; then
    echo "ERROR: source incomplete"
    exit 1
fi



#################################
# SYSTEMD FILES
#################################

mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
-name "*config-location*" \
-exec cp {} "$WORK/systemd/" \; \
2>/dev/null || true



#################################
# NGINX
#################################

mkdir -p "$WORK/nginx"


nginx -T \
> "$WORK/nginx/nginx.txt" \
2>&1 || true



#################################
# DEPENDENCY
#################################

mkdir -p "$WORK/dependencies"


find "$SOURCE" \
-type f \
\( \
-name "requirements*.txt" \
-o -name "pyproject.toml" \
-o -name "setup.py" \
\) \
-exec cp --parents {} "$WORK/dependencies/" \; \
2>/dev/null || true



#################################
# COMPRESS
#################################

echo "[5] Compress"


tar -cf - \
-C "/root" \
"$NAME" \
| zstd -15 -T0 -o "$OUT"



sha256sum "$OUT" > "$OUT.sha256"



#################################
# START SERVICES AGAIN
#################################

echo "[6] Start services"


for S in $SERVICES
do
    systemctl start "$S" 2>/dev/null || true
done



#################################
# CLEAN
#################################

rm -rf "$WORK"



echo
echo "DONE"

ls -lh "$OUT"

echo "$OUT"
echo "$OUT.sha256"
echo "$REPORT"

