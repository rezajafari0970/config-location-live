#!/usr/bin/env bash
set -Eeuo pipefail

BASE=/root/snapshots

WORK=$(
    find "$BASE" \
    -maxdepth 1 \
    -mindepth 1 \
    -type d \
    -name 'config-location-PRE-PANEL-FULL-*' \
    -printf '%T@ %p\n' \
    | sort -nr \
    | head -n1 \
    | cut -d' ' -f2-
)

test -n "$WORK"
test -d "$WORK"
test -s "$WORK/MANIFEST.json"

SNAPSHOT_NAME=$(basename "$WORK")

ARCHIVE="$BASE/$SNAPSHOT_NAME.tar.gz"
SHA="$ARCHIVE.sha256"

echo "======================================================"
echo " PRE-PANEL SNAPSHOT FINALIZER"
echo "======================================================"

echo "WORK=$WORK"
echo "SNAPSHOT_NAME=$SNAPSHOT_NAME"
echo "ARCHIVE=$ARCHIVE"


echo
echo "=== 1. MANIFEST ==="

cat "$WORK/MANIFEST.json"

echo
echo "MANIFEST_FOUND=PASS"


echo
echo "=== 2. WORKDIR SIZE ==="

du -sh "$WORK"

FILES=$(
    find "$WORK" \
    -type f \
    | wc -l
)

DIRS=$(
    find "$WORK" \
    -type d \
    | wc -l
)

echo "FILES=$FILES"
echo "DIRECTORIES=$DIRS"

test "$FILES" -gt 1000

echo "WORKDIR_CONTENT=PASS"


echo
echo "=== 3. REMOVE PARTIAL ARCHIVE IF ANY ==="

rm -f \
"$ARCHIVE" \
"$SHA"

echo "OLD_PARTIAL_REMOVED=YES"


echo
echo "=== 4. CREATE ARCHIVE ==="

tar \
-C "$BASE" \
-czf "$ARCHIVE" \
"$SNAPSHOT_NAME"

test -s "$ARCHIVE"

echo "ARCHIVE_CREATED=PASS"

ls -lh "$ARCHIVE"


echo
echo "=== 5. SHA256 ==="

sha256sum "$ARCHIVE" \
>"$SHA"

cat "$SHA"

echo "SHA256_CREATED=PASS"


echo
echo "=== 6. TAR INTEGRITY TEST ==="

gzip -t "$ARCHIVE"

echo "GZIP_VERIFY=PASS"

tar -tzf "$ARCHIVE" \
>/dev/null

echo "TAR_VERIFY=PASS"


echo
echo "=== 7. SHA256 VERIFY ==="

cd "$BASE"

sha256sum -c \
"$(basename "$SHA")"

echo "SHA256_VERIFY=PASS"


echo
echo "=== 8. CRITICAL CONTENT VERIFY ==="

for ITEM in \
MANIFEST.json \
project \
state \
systemd \
panel \
xray \
devlog \
journal \
network \
system \
integrity \
audit \
reports \
root-scripts
do

    test -e "$WORK/$ITEM"

    echo "$ITEM=PASS"
done

echo "CRITICAL_CONTENT=PASS"


echo
echo "=== 9. FINAL SERVICES ==="

for S in \
config-location-panel.service \
config-location-fetcher.service \
config-location-health-adaptive.service \
config-location-country-worker.service \
config-location-country-event-consumer.service \
config-location-lifecycle-sync.service \
config-location-lifecycle-watchdog.service
do

    X=$(
        systemctl is-active \
        "$S" 2>/dev/null || true
    )

    echo "$S=$X"

    test "$X" = active
done

echo "SERVICES=PASS"


echo
echo "======================================================"
echo "PRE_PANEL_FULL_SNAPSHOT=PASS"
echo "ARCHIVE_VERIFY=PASS"
echo "ARCHIVE=$ARCHIVE"
echo "SHA256=$SHA"
echo "WORKDIR=$WORK"
echo "READY_FOR_PANEL_DEVELOPMENT=YES"
echo "======================================================"
