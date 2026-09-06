#!/bin/bash

set -Eeuo pipefail


#########################################
# CONFIG
#########################################

SRC="/root/aop/config-location-production-audit-20260904-021830.tar.gz"

BASE="/root/aop"

DATE=$(date +"%Y%m%d-%H%M%S")

NAME="config-location-final-$DATE"

WORK="$BASE/work-$DATE"

OUT="$BASE/$NAME.tar.zst"

REPORT="$BASE/$NAME-report"

LOG="$BASE/$NAME.log"

LOCK="/tmp/config-location-snapshot.lock"



#########################################
# LOCK
#########################################

if [ -e "$LOCK" ]; then
    echo "Another snapshot is running"
    exit 1
fi

touch "$LOCK"


cleanup()
{
    rm -f "$LOCK"
}

trap cleanup EXIT



#########################################
# LOG
#########################################

exec > >(tee -a "$LOG") 2>&1



echo "================================="
echo " CONFIG LOCATION FAST SNAPSHOT"
echo "$(date)"
echo "================================="



#########################################
# PERFORMANCE BOOST
#########################################

CPU_COUNT=$(nproc)

echo "CPU Threads: $CPU_COUNT"


renice -n -10 -p $$ >/dev/null 2>&1 || true


ionice -c2 -n0 -p $$ >/dev/null 2>&1 || true


export ZSTD_NBTHREADS="$CPU_COUNT"



#########################################
# CHECK SOURCE
#########################################

if [ ! -f "$SRC" ]; then
    echo "SOURCE NOT FOUND"
    exit 1
fi



FREE=$(df -Pm "$BASE" | awk 'NR==2 {print $4}')

SIZE=$(du -m "$SRC" | awk '{print $1}')


echo "Source size: ${SIZE} MB"
echo "Free space : ${FREE} MB"


NEED=$((SIZE * 3))


if [ "$FREE" -lt "$NEED" ]; then

    echo "NOT ENOUGH SPACE"
    echo "Need ${NEED} MB"

    exit 1

fi



#########################################
# PREPARE
#########################################

rm -rf "$WORK"

mkdir -p "$WORK"
mkdir -p "$REPORT"



#########################################
# EXTRACT
#########################################

echo "[1] Extracting"


time tar \
-xzf "$SRC" \
-C "$WORK"



ROOT=$(find "$WORK" -mindepth 1 -maxdepth 1 -type d | head -1)


if [ -z "$ROOT" ]; then
    echo "Extraction failed"
    exit 1
fi



du -sh "$ROOT" \
> "$REPORT/before-size.txt"



#########################################
# INVENTORY BEFORE
#########################################

echo "[2] Inventory"


find "$ROOT" \
-type f \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/before-files.txt"



#########################################
# SAFE CLEAN
#########################################

echo "[3] Removing unnecessary"


find "$ROOT" \
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



#########################################
# VERIFY IMPORTANT MODULES
#########################################

echo "[4] Verify modules"


for M in \
app \
panel \
publish \
health \
country \
parser \
storage \
state \
runtime \
configs \
raw \
queues \
remark \
ranking

do

if [ -e "$ROOT/$M" ]
then
    echo "$M : OK"
else
    echo "$M : MISSING"
fi

done > "$REPORT/modules.txt"



#########################################
# AFTER SIZE
#########################################

du -sh "$ROOT" \
> "$REPORT/after-size.txt"



find "$ROOT" \
-type f \
-size +20M \
-printf "%s %p\n" \
| sort -nr \
> "$REPORT/large-files.txt"



#########################################
# COMPRESS FAST
#########################################

echo "[5] Compressing"

echo "Using $CPU_COUNT CPU threads"


time tar \
--use-compress-program="zstd -15 -T$CPU_COUNT --long=27" \
--checkpoint=1000 \
-cf "$OUT" \
-C "$WORK" \
"$(basename "$ROOT")"



#########################################
# SHA256
#########################################

echo "[6] SHA256"


sha256sum "$OUT" \
> "$OUT.sha256"



#########################################
# CLEAN WORK
#########################################

rm -rf "$WORK"



#########################################
# FINAL
#########################################

echo
echo "================================="
echo " COMPLETE"
echo "================================="


ls -lh "$OUT"

echo "$OUT"

echo "$OUT.sha256"

echo "$REPORT"

