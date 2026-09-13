#!/usr/bin/env bash

set -Eeuo pipefail


PROJECT="/opt/config-location"

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

WORK="$BASE/config-location-master-audit-$DATE"

ARCHIVE="$BASE/config-location-master-audit-$DATE.tar.gz"


mkdir -p "$WORK"


echo "=========================================="
echo " CONFIG LOCATION MASTER AUDIT SNAPSHOT"
echo "=========================================="


############################################
# SYSTEM INFO
############################################

mkdir -p "$WORK/system"

{
echo "DATE"
date

echo
echo "HOST"
hostname

echo
echo "OS"
cat /etc/os-release

echo
echo "KERNEL"
uname -a

echo
echo "CPU"
lscpu

echo
echo "RAM"
free -h

echo
echo "DISK"
df -h

} > "$WORK/system/system-info.txt"



############################################
# COMPLETE PROJECT COPY
############################################

echo "[1] Copy full project"

mkdir -p "$WORK/project"


rsync -aHAX \
--numeric-ids \
--exclude='.git' \
--exclude='venv' \
--exclude='.venv' \
--exclude='node_modules' \
--exclude='__pycache__' \
--exclude='*.pyc' \
--exclude='*.pyo' \
--exclude='*.log' \
--exclude='logs' \
--exclude='backup' \
--exclude='backups' \
--exclude='cache' \
"$PROJECT/" \
"$WORK/project/"



############################################
# EXCLUDED FILE REPORT
############################################

echo "[2] Excluded files report"

mkdir -p "$WORK/reports"


find "$PROJECT" \
\( \
-name "venv" \
-o -name ".venv" \
-o -name "node_modules" \
-o -name "__pycache__" \
-o -name "*.pyc" \
-o -name "*.log" \
-o -name "logs" \
-o -name "backup" \
-o -name "backups" \
-o -name "cache" \
\) \
> "$WORK/reports/excluded-files.txt" \
2>/dev/null || true



############################################
# ALL FILE INVENTORY
############################################

echo "[3] Inventory"

find "$PROJECT" \
-type f \
-printf "%p | %s bytes | %u:%g | %m\n" \
| sort \
> "$WORK/reports/full-file-inventory.txt"



############################################
# LARGE FILE DETECTION
############################################

echo "[4] Large files"

find "$PROJECT" \
-type f \
-size +50M \
-printf "%s bytes %p\n" \
| sort -nr \
> "$WORK/reports/large-files.txt"



############################################
# SOURCE MAP
############################################

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
-o -name "*.toml" \
\) \
| sort \
> "$WORK/reports/source-code-map.txt"



############################################
# DEPENDENCIES
############################################

echo "[5] Dependencies"

mkdir -p "$WORK/dependencies"


find "$PROJECT" \
-type f \
\( \
-name "requirements*.txt" \
-o -name "pyproject.toml" \
-o -name "setup.py" \
-o -name "package.json" \
-o -name "composer.json" \
\) \
-exec cp --parents {} "$WORK/dependencies/" \; \
2>/dev/null || true


python3 --version \
> "$WORK/dependencies/python-version.txt" 2>&1 || true


pip3 freeze \
> "$WORK/dependencies/pip-freeze.txt" 2>&1 || true



############################################
# SYSTEMD
############################################

echo "[6] Systemd"

mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
\( \
-name "*config-location*" \
-o -name "*country*" \
-o -name "*health*" \
-o -name "*fetch*" \
\) \
-exec cp {} "$WORK/systemd/" \; \
2>/dev/null || true



systemctl list-unit-files \
> "$WORK/systemd/all-units.txt"



for SERVICE in $(systemctl list-units --all \
| grep -Ei "config|location|country|health|fetch" \
| awk '{print $1}')
do

systemctl cat "$SERVICE" \
> "$WORK/systemd/$SERVICE.config.txt" \
2>&1 || true


systemctl status "$SERVICE" \
--no-pager \
> "$WORK/systemd/$SERVICE.status.txt" \
2>&1 || true


journalctl \
-u "$SERVICE" \
-n 500 \
--no-pager \
> "$WORK/systemd/$SERVICE.last500.log" \
2>&1 || true

done



############################################
# RUNTIME STRUCTURE ONLY
############################################

echo "[7] Runtime"

mkdir -p "$WORK/runtime"


for DIR in \
/var/lib/config-location \
/var/run/config-location \
/run/config-location
do

if [ -d "$DIR" ]; then

echo "$DIR" >> "$WORK/runtime/paths.txt"

du -sh "$DIR" \
>> "$WORK/runtime/size.txt"


find "$DIR" \
-maxdepth 2 \
-type f \
-printf "%p | %s bytes\n" \
>> "$WORK/runtime/files.txt"

fi

done



############################################
# SECURITY
############################################

echo "[8] Permissions"

mkdir -p "$WORK/security"


find "$PROJECT" \
-printf "%M %u %g %s %p\n" \
> "$WORK/security/permissions.txt"


stat "$PROJECT" \
> "$WORK/security/root-stat.txt"



############################################
# NGINX
############################################

echo "[9] Nginx"

mkdir -p "$WORK/nginx"


nginx -T \
> "$WORK/nginx/nginx-full.txt" \
2>&1 || true


grep -Ril \
"config-location\|4040\|panel\|sub\|publish" \
/etc/nginx \
2>/dev/null \
| while read FILE
do
cp --parents "$FILE" "$WORK/nginx/" 2>/dev/null || true
done



############################################
# NETWORK + PROCESS
############################################

mkdir -p "$WORK/runtime-status"


ss -lntup \
> "$WORK/runtime-status/ports.txt"


ps auxww \
> "$WORK/runtime-status/process.txt"


pstree -ap \
> "$WORK/runtime-status/process-tree.txt" \
2>/dev/null || true



############################################
# PROJECT MAP
############################################

cat > "$WORK/PROJECT-MAP.txt" <<MAP

CONFIG LOCATION

Pipeline:

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


Snapshot:
$(date)

MAP



############################################
# SHA256
############################################

echo "[10] SHA256"

cd "$WORK"

find . \
-type f \
-print0 \
| sort -z \
| xargs -0 sha256sum \
> SHA256-MANIFEST.txt



############################################
# ARCHIVE
############################################

echo "[11] Archive"

cd "$BASE"


tar \
-czf "$ARCHIVE" \
"$(basename "$WORK")"



sha256sum "$ARCHIVE" \
> "$ARCHIVE.sha256"



rm -rf "$WORK"


echo
echo "=================================="
echo " COMPLETE"
echo "=================================="

echo "$ARCHIVE"

echo "$ARCHIVE.sha256"


