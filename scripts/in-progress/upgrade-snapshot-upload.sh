#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

TARGET="/usr/local/bin/snapshot-upload"

echo "=============================================="
echo " UPGRADING snapshot-upload"
echo "=============================================="

if [[ ! -x "$TARGET" ]]; then
    echo "[ERROR] $TARGET not found"
    exit 1
fi

cp -a "$TARGET" "${TARGET}.bak.$(date +%Y%m%d-%H%M%S)"

cat >"$TARGET" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REMOTE="gdrive"
SRC="/root/cus"
DST="CONFIG-LOCATION/snapshots"
STATE="/root/cus/LAST-GDRIVE-SNAPSHOT.txt"

echo "=================================================="
echo " CONFIG LOCATION SNAPSHOT UPLOAD"
echo "=================================================="

rclone about "${REMOTE}:" >/dev/null

mapfile -t FILES < <(
    find "$SRC" -maxdepth 1 -type f \
        -name 'CONFIG-LOCATION-ZERO-TO-100-*.tar.gz' \
        -printf '%T@ %p\n' |
    sort -nr |
    cut -d' ' -f2-
)

if (( ${#FILES[@]} == 0 )); then
    echo "[ERROR] No snapshot archives found."
    exit 1
fi

: > "$STATE"

for FILE in "${FILES[@]}"; do
    NAME="$(basename "$FILE")"
    SHA="${FILE}.sha256"
    SHA_NAME="$(basename "$SHA")"

    echo
    echo "----------------------------------------------"
    echo "Snapshot: $NAME"
    echo "----------------------------------------------"

    echo "[1] SHA256..."
    sha256sum "$FILE" > "$SHA"

    echo "[2] Upload archive..."
    rclone copyto \
        "$FILE" \
        "${REMOTE}:${DST}/${NAME}" \
        --progress \
        --stats 5s \
        --retries 5 \
        --low-level-retries 20

    echo "[3] Upload SHA256..."
    rclone copyto \
        "$SHA" \
        "${REMOTE}:${DST}/${SHA_NAME}" \
        --retries 5 \
        --low-level-retries 20

    echo "[4] Verify archive size..."
    LOCAL_SIZE="$(stat -c '%s' "$FILE")"

    REMOTE_SIZE="$(
        rclone size "${REMOTE}:${DST}/${NAME}" --json |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])'
    )"

    if [[ "$LOCAL_SIZE" != "$REMOTE_SIZE" ]]; then
        echo "[ERROR] VERIFY FAILED"
        echo "LOCAL=$LOCAL_SIZE"
        echo "REMOTE=$REMOTE_SIZE"
        exit 1
    fi

    echo "[OK] Archive verified"

    echo "[5] Reading Drive IDs..."

    ARCH_ID="$(
        rclone lsjson "${REMOTE}:${DST}" \
            --files-only \
            --no-mimetype \
            --no-modtime |
        python3 - "$NAME" <<'PY'
import json,sys
name=sys.argv[1]
data=json.load(sys.stdin)
for x in data:
    if x.get("Name")==name:
        print(x.get("ID",""))
        break
PY
    )"

    SHA_ID="$(
        rclone lsjson "${REMOTE}:${DST}" \
            --files-only \
            --no-mimetype \
            --no-modtime |
        python3 - "$SHA_NAME" <<'PY'
import json,sys
name=sys.argv[1]
data=json.load(sys.stdin)
for x in data:
    if x.get("Name")==name:
        print(x.get("ID",""))
        break
PY
    )"

    ARCH_LINK=""
    SHA_LINK=""

    if [[ -n "$ARCH_ID" ]]; then
        ARCH_LINK="https://drive.google.com/file/d/${ARCH_ID}/view"
    fi

    if [[ -n "$SHA_ID" ]]; then
        SHA_LINK="https://drive.google.com/file/d/${SHA_ID}/view"
    fi

    {
        echo "TIMESTAMP=$(date -Is)"
        echo "ARCHIVE_NAME=$NAME"
        echo "ARCHIVE_SIZE=$LOCAL_SIZE"
        echo "ARCHIVE_ID=$ARCH_ID"
        echo "ARCHIVE_LINK=$ARCH_LINK"
        echo "SHA_NAME=$SHA_NAME"
        echo "SHA_ID=$SHA_ID"
        echo "SHA_LINK=$SHA_LINK"
        echo
    } >> "$STATE"

    echo
    echo "ARCHIVE"
    echo "Name : $NAME"
    echo "ID   : ${ARCH_ID:-NOT-AVAILABLE}"
    echo "Link : ${ARCH_LINK:-NOT-AVAILABLE}"

    echo
    echo "SHA256"
    echo "Name : $SHA_NAME"
    echo "ID   : ${SHA_ID:-NOT-AVAILABLE}"
    echo "Link : ${SHA_LINK:-NOT-AVAILABLE}"
done

chmod 600 "$STATE"

echo
echo "=================================================="
echo " SNAPSHOT UPLOAD + VERIFY + DRIVE ID SUCCESS"
echo "=================================================="
echo
echo "Saved:"
echo "  $STATE"
SCRIPT

chmod 700 "$TARGET"

cat >/usr/local/bin/snapshot-last-link <<'SCRIPT'
#!/usr/bin/env bash
cat /root/cus/LAST-GDRIVE-SNAPSHOT.txt
SCRIPT

chmod 700 /usr/local/bin/snapshot-last-link

echo
echo "[OK] Upgrade installed"
echo
echo "Running upgraded uploader now..."
echo

snapshot-upload
