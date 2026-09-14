#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SRC="/root/cus"
REMOTE="gdrive"
DRIVE_ROOT="CONFIG-LOCATION/snapshots/chunks"

ARCHIVE="$(
  find "$SRC" -maxdepth 1 -type f \
    -name 'CONFIG-LOCATION-ZERO-TO-100-*.tar.gz' \
    -printf '%T@ %p\n' |
  sort -nr |
  head -n1 |
  cut -d' ' -f2-
)"

if [[ -z "${ARCHIVE:-}" || ! -f "$ARCHIVE" ]]; then
    echo "[ERROR] Snapshot archive not found"
    exit 1
fi

NAME="$(basename "$ARCHIVE")"
SNAP="${NAME%.tar.gz}"
WORK="/root/cus/.drive-chunks/$SNAP"
DEST="$DRIVE_ROOT/$SNAP"

echo "=================================================="
echo " SNAPSHOT CHUNK UPLOAD FOR CHATGPT"
echo "=================================================="
echo "Archive: $ARCHIVE"
echo "Drive:   $DEST"
echo

rm -rf "$WORK"
mkdir -p "$WORK"

echo "[1/6] Calculating original SHA256..."
sha256sum "$ARCHIVE" | tee "$WORK/ARCHIVE.sha256"

echo
echo "[2/6] Splitting into 200 MiB pieces..."

split \
  --bytes=200M \
  --numeric-suffixes=0 \
  --suffix-length=3 \
  --additional-suffix=.bin \
  "$ARCHIVE" \
  "$WORK/part-"

echo
ls -lh "$WORK"/part-*.bin

echo
echo "[3/6] Creating chunk SHA256 list..."

(
  cd "$WORK"
  sha256sum part-*.bin > CHUNKS.sha256
)

cat "$WORK/CHUNKS.sha256"

echo
echo "[4/6] Creating manifest..."

python3 - "$ARCHIVE" "$WORK" "$NAME" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

archive, work, name = sys.argv[1:]
work = Path(work)

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(b)
    return h.hexdigest()

parts = sorted(work.glob("part-*.bin"))

manifest = {
    "archive_name": name,
    "archive_size": os.path.getsize(archive),
    "archive_sha256": sha256(archive),
    "chunk_size_target": 200 * 1024 * 1024,
    "chunk_count": len(parts),
    "chunks": [
        {
            "name": p.name,
            "size": p.stat().st_size,
            "sha256": sha256(p),
        }
        for p in parts
    ],
}

(work / "MANIFEST.json").write_text(
    json.dumps(manifest, indent=2),
    encoding="utf-8"
)

print(json.dumps(manifest, indent=2))
PY

echo
echo "[5/6] Uploading chunks + manifests..."

rclone mkdir "${REMOTE}:${DEST}"

rclone copy "$WORK/" "${REMOTE}:${DEST}/" \
    --progress \
    --stats 5s \
    --retries 5 \
    --low-level-retries 20

echo
echo "[6/6] Verifying remote files..."

rclone check \
    "$WORK/" \
    "${REMOTE}:${DEST}/" \
    --one-way

echo
echo "===== DRIVE CONTENT ====="
rclone lsf "${REMOTE}:${DEST}/" --format 'sp'

echo
echo "=================================================="
echo " CHUNK UPLOAD + VERIFY SUCCESS"
echo "=================================================="
echo "Drive folder:"
echo "$DEST"
