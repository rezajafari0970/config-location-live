#!/bin/bash

set -Eeuo pipefail

PROJECT="/opt/config-location"
BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-source-only-$DATE"

WORK="/tmp/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"


mkdir -p "$WORK" "$REPORT"


echo "================================="
echo " CONFIG LOCATION SOURCE ONLY"
echo "================================="


####################################
# COPY SOURCE
####################################

echo "[1] Copy source"

mkdir -p "$WORK/project"

rsync -aHAX \
--numeric-ids \
"$PROJECT/" \
"$WORK/project/"


####################################
# REMOVE NON SOURCE
####################################

echo "[2] Remove non source data"


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
-o -name "backup" \
-o -name "backups" \
-o -name "archive" \
-o -name "*.tar.gz" \
-o -name "*.tar" \
-o -name "*.zip" \
\) \
-print \
> "$REPORT/removed-files.txt"


while read -r F
do
    [ -e "$F" ] && rm -rf "$F"
done < "$REPORT/removed-files.txt"



####################################
# KEEP IMPORTANT TREE
####################################

find "$WORK/project" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/source-files.txt"



du -sh "$WORK/project" \
> "$REPORT/source-size.txt"



####################################
# SYSTEMD
####################################

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



####################################
# NGINX
####################################

mkdir -p "$WORK/nginx"


nginx -T \
> "$REPORT/nginx-full.txt" \
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
# DEPENDENCY
####################################

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



####################################
# ARCHITECTURE MAP
####################################

cat > "$WORK/ARCHITECTURE.txt" <<MAP

CONFIG LOCATION SOURCE MAP

Source
 |
Fetcher
 |
Parser
 |
Normalize
 |
Storage
 |
Country Detection
 |
Health Check
 |
Lifecycle
 |
Publish
 |
Panel


MAP



####################################
# SHA256
####################################

cd "$WORK"

find . \
-type f \
-print0 \
| sort -z \
| xargs -0 sha256sum \
> SHA256-MANIFEST.txt



####################################
# COMPRESS
####################################

cd "$BASE"

tar --zstd -15 -cf "$OUT" \
-C "$WORK/.." \
"$NAME"


sha256sum "$OUT" \
> "$OUT.sha256"



rm -rf "$WORK"


echo
echo "DONE"
echo "$OUT"
echo "$OUT.sha256"

