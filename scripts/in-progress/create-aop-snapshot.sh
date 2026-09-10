#!/bin/bash
set -Eeuo pipefail

PROJECT="/opt/config-location"

OUTDIR="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

WORK="$OUTDIR/config-location-aop-$DATE"
ARCHIVE="$OUTDIR/config-location-aop-$DATE.tar.gz"

mkdir -p "$WORK"


echo "================================="
echo " CONFIG LOCATION AOP SNAPSHOT"
echo "================================="


####################################
# PROJECT SOURCE
####################################

echo "[1] Source"

mkdir -p "$WORK/project"

rsync -aH \
--exclude=".git" \
--exclude="venv" \
--exclude=".venv" \
--exclude="__pycache__" \
--exclude="*.pyc" \
--exclude="*.pyo" \
--exclude="*.log" \
--exclude="logs" \
--exclude="backup" \
--exclude="backups" \
--exclude="cache" \
--exclude="tmp" \
"$PROJECT/" \
"$WORK/project/"


####################################
# SOURCE MAP
####################################

echo "[2] Code map"

find "$PROJECT" \
-type f \
\( \
-name "*.py" \
-o -name "*.sh" \
-o -name "*.php" \
-o -name "*.js" \
-o -name "*.json" \
-o -name "*.yaml" \
-o -name "*.yml" \
\) \
| sort \
> "$WORK/source-files.txt"



####################################
# DEPENDENCY
####################################

echo "[3] Dependencies"

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


python3 --version \
> "$WORK/dependencies/python.txt" 2>&1 || true


pip3 freeze \
> "$WORK/dependencies/pip-freeze.txt" 2>&1 || true



####################################
# SYSTEMD
####################################

echo "[4] Systemd"

mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
-name "*config-location*" \
-exec cp {} "$WORK/systemd/" \; \
2>/dev/null || true


systemctl list-unit-files \
| grep -Ei "config|location|country|health" \
> "$WORK/systemd/services.txt" || true


for S in $(systemctl list-units --all \
| grep -Ei "config|location|country|health" \
| awk '{print $1}')
do

systemctl cat "$S" \
> "$WORK/systemd/$S.txt" \
2>&1 || true

systemctl status "$S" \
--no-pager \
> "$WORK/systemd/$S.status.txt" \
2>&1 || true

journalctl -u "$S" \
-n 300 \
--no-pager \
> "$WORK/systemd/$S.error-last300.log" \
2>&1 || true

done



####################################
# RUNTIME SUMMARY
####################################

echo "[5] Runtime"

mkdir -p "$WORK/runtime"


for P in \
/var/lib/config-location \
/var/run/config-location \
/run/config-location
do

if [ -e "$P" ]; then

du -sh "$P" \
>> "$WORK/runtime/size.txt"

find "$P" \
-maxdepth 2 \
-type f \
| head -200 \
>> "$WORK/runtime/files.txt"

fi

done



####################################
# PERMISSION
####################################

echo "[6] Permission"

mkdir -p "$WORK/security"


stat "$PROJECT" \
> "$WORK/security/project-stat.txt"


find "$PROJECT" \
-maxdepth 4 \
-printf "%M %u %g %s %p\n" \
> "$WORK/security/tree.txt"



####################################
# NGINX
####################################

echo "[7] Nginx"

mkdir -p "$WORK/nginx"


nginx -T \
> "$WORK/nginx/full.txt" \
2>&1 || true


grep -Ril \
"config-location\|4040\|panel\|sub" \
/etc/nginx \
2>/dev/null \
| while read F
do
cp --parents "$F" "$WORK/nginx/" 2>/dev/null || true
done



####################################
# PROCESS AND PORT
####################################

echo "[8] Runtime status"

mkdir -p "$WORK/status"


ss -lntup \
> "$WORK/status/ports.txt"


ps auxww \
> "$WORK/status/process.txt"


pstree -ap \
> "$WORK/status/tree.txt" \
2>/dev/null || true



####################################
# ARCHITECTURE MAP
####################################

cat > "$WORK/PROJECT-MAP.txt" <<MAP

CONFIG LOCATION

Architecture:

Sources
 |
 v
Fetcher
 |
 v
Parser
 |
 v
Normalize
 |
 v
Storage
 |
 v
Country Detection
 |
 v
Health Check
 |
 v
Lifecycle
 |
 v
Publish
 |
 v
Panel / Subscription


Project:
$PROJECT

Created:
$(date)

MAP



####################################
# MANIFEST
####################################

echo "[9] SHA256"

cd "$WORK"

find . \
-type f \
-print0 \
| sort -z \
| xargs -0 sha256sum \
> SHA256.txt



####################################
# ARCHIVE
####################################

echo "[10] Archive"

cd "$OUTDIR"

tar -czf "$ARCHIVE" \
"$(basename "$WORK")"


sha256sum "$ARCHIVE" \
> "$ARCHIVE.sha256"


rm -rf "$WORK"


echo
echo "DONE"
echo
echo "$ARCHIVE"
echo "$ARCHIVE.sha256"

