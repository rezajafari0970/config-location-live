#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REMOTE="gdrive"
BASE="/var/lib/config-location/storage"

echo "======================================"
echo " FIX GOOGLE DRIVE STORAGE MANAGER"
echo "======================================"

mkdir -p "$BASE"/{archive,manifests,logs}


echo "[1/6] Checking rclone remote..."

if ! rclone listremotes | grep -qx "${REMOTE}:"; then
    echo "ERROR: gdrive remote not found"
    exit 1
fi


echo "[2/6] Creating Drive folders..."

rclone mkdir "${REMOTE}:snapshots"
rclone mkdir "${REMOTE}:snapshots/full"
rclone mkdir "${REMOTE}:snapshots/verified"


echo "[3/6] Fixing commands..."

for f in \
 /usr/local/bin/gdrive-status \
 /usr/local/bin/snapshot-create \
 /usr/local/bin/snapshot-list \
 /usr/local/bin/snapshot-latest \
 /usr/local/bin/snapshot-verify
do
    [ -f "$f" ] && sed -i "s#CONFIG-LOCATION#${REMOTE}#g" "$f"
done


echo "[4/6] Testing Drive..."

rclone about "${REMOTE}:"


echo "[5/6] Listing snapshots..."

rclone lsf "${REMOTE}:snapshots" || true


echo "[6/6] Creating storage state..."

cat > "$BASE/storage-status.json" <<JSON
{
 "remote":"${REMOTE}",
 "path":"snapshots",
 "time":"$(date -Is)",
 "status":"connected"
}
JSON


echo
echo "======================================"
echo " GOOGLE DRIVE STORAGE FIX COMPLETE"
echo "======================================"

echo
echo "Commands:"
echo " snapshot-list"
echo " snapshot-create"
echo " snapshot-latest"
echo " snapshot-verify"

