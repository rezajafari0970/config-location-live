#!/bin/bash

set -Eeuo pipefail


BASE="/root/aop"

PROJECT="/opt/config-location"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-source-discovered-$DATE"

WORK="/root/$NAME"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"



mkdir -p "$WORK"
mkdir -p "$REPORT"



echo "======================================"
echo " SOURCE DISCOVERY + SNAPSHOT"
echo "======================================"



####################################
# DISCOVER
####################################

echo "[1] Discover project"


du -h --max-depth=3 "$PROJECT" \
| sort -h \
> "$REPORT/size-map.txt"



find "$PROJECT" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/all-files.txt"



CODE_COUNT=$(find "$PROJECT" \
-type f \
\( \
-name "*.py" \
-o -name "*.sh" \
-o -name "*.js" \
-o -name "*.php" \
\) | wc -l)



echo "Code files: $CODE_COUNT" \
> "$REPORT/code-count.txt"



####################################
# COPY WITHOUT OVER FILTERING
####################################

echo "[2] Copy source"


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
"$PROJECT/" \
"$WORK/project/"



####################################
# VERIFY COPY
####################################

ORIGINAL=$(du -sm "$PROJECT" | awk '{print $1}')

COPIED=$(du -sm "$WORK/project" | awk '{print $1}')


echo "Original MB: $ORIGINAL" \
> "$REPORT/copy-check.txt"

echo "Copied MB: $COPIED" \
>> "$REPORT/copy-check.txt"



if [ "$COPIED" -lt 1 ]; then

echo "COPY FAILED"
exit 1

fi



####################################
# SYSTEMD
####################################

mkdir -p "$WORK/systemd"


find /etc/systemd/system \
-type f \
\( \
-name "*config-location*" \
-o -name "*health*" \
-o -name "*country*" \
-o -name "*fetch*" \
\) \
-exec cp {} "$WORK/systemd/" \; \
2>/dev/null || true



####################################
# NGINX
####################################

mkdir -p "$WORK/nginx"


nginx -T \
> "$WORK/nginx/nginx.txt" \
2>&1 || true



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
\) \
-exec cp --parents {} "$WORK/dependencies/" \; \
2>/dev/null || true



####################################
# COMPRESS
####################################

echo "[3] Compress"


tar -cf - \
-C "/root" \
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

