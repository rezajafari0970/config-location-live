#!/bin/bash
set -Eeuo pipefail

PROJECT="/opt/config-location"

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-analysis-$DATE"

WORK="$BASE/$NAME"

ARCHIVE="$BASE/$NAME.tar.gz"


mkdir -p "$WORK"

echo "======================================"
echo " CONFIG LOCATION ANALYSIS SNAPSHOT"
echo "======================================"


#################################
# COPY FULL PROJECT
#################################

echo "[1] Copy project"

mkdir -p "$WORK/project"

rsync -aHAX \
--numeric-ids \
"$PROJECT/" \
"$WORK/project/"


#################################
# REMOVE ONLY UNNECESSARY
#################################

echo "[2] Removing unnecessary"


mkdir -p "$WORK/reports"


find "$WORK/project" \
\( \
-name "venv" \
-o -name ".venv" \
-o -name "node_modules" \
-o -name ".git" \
-o -name "__pycache__" \
-o -name "*.pyc" \
-o -name "*.pyo" \
-o -name "*.log" \
-o -name "logs" \
-o -name "backups" \
-o -name "*.tar.gz" \
-o -name "*.zip" \
\) \
-print \
> "$WORK/reports/removed.txt"


while read -r F
do
[ -e "$F" ] && rm -rf "$F"
done < "$WORK/reports/removed.txt"



#################################
# FILE INVENTORY
#################################

echo "[3] Inventory"


find "$WORK/project" \
-type f \
-printf "%p | %s bytes | %u:%g | %m\n" \
| sort \
> "$WORK/reports/files-after-clean.txt"



#################################
# IMPORTANT DIRECTORIES REPORT
#################################

echo "[4] Important paths"


for D in \
app \
panel \
publish \
health \
country \
parser \
fetcher \
storage \
state \
runtime \
configs \
raw \
queues \
remark \
ranking \
relations \
sources
do

if [ -d "$WORK/project/$D" ]; then

du -sh "$WORK/project/$D" \
>> "$WORK/reports/important-paths.txt"

fi

done



#################################
# LARGE FILE REPORT
#################################

find "$WORK/project" \
-type f \
-size +20M \
-printf "%s bytes %p\n" \
| sort -nr \
> "$WORK/reports/large-files.txt"



#################################
# SOURCE MAP
#################################

find "$WORK/project" \
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
> "$WORK/reports/source-map.txt"



#################################
# SYSTEMD
#################################

echo "[5] Systemd"

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
> "$WORK/systemd/unit-list.txt"


systemctl list-units --all \
> "$WORK/systemd/running.txt"



#################################
# NGINX
#################################

echo "[6] Nginx"

mkdir -p "$WORK/nginx"


nginx -T \
> "$WORK/nginx/full.txt" \
2>&1 || true


grep -Ril \
"config-location\|4040\|sub\|panel" \
/etc/nginx \
2>/dev/null \
| while read F
do
cp --parents "$F" "$WORK/nginx/" 2>/dev/null || true
done



#################################
# DEPENDENCY
#################################

echo "[7] Dependency"

mkdir -p "$WORK/dependency"


find "$PROJECT" \
-type f \
\( \
-name "requirements*.txt" \
-o -name "pyproject.toml" \
-o -name "setup.py" \
\) \
-exec cp --parents {} "$WORK/dependency/" \; \
2>/dev/null || true


pip3 freeze \
> "$WORK/dependency/pip-freeze.txt" 2>&1 || true



#################################
# PERMISSION
#################################

mkdir -p "$WORK/security"


find "$WORK/project" \
-printf "%M %u %g %s %p\n" \
> "$WORK/security/permissions.txt"



#################################
# ARCHITECTURE
#################################

cat > "$WORK/ARCHITECTURE.txt" <<MAP

CONFIG LOCATION

Source
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


MAP



#################################
# SHA256
#################################

cd "$WORK"

find . \
-type f \
-print0 \
| sort -z \
| xargs -0 sha256sum \
> SHA256.txt



#################################
# ARCHIVE
#################################

cd "$BASE"

tar -czf "$ARCHIVE" "$NAME"

sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"


rm -rf "$WORK"


echo
echo "DONE"
echo "$ARCHIVE"
echo "$ARCHIVE.sha256"

