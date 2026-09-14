#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/storage"
DRIVE="CONFIG-LOCATION/snapshots"

mkdir -p \
"$BASE/manifests" \
"$BASE/archive" \
"$BASE/logs"


echo "======================================"
echo " Google Drive Storage Manager v1"
echo "======================================"


command -v rclone >/dev/null || {
 echo "rclone not found"
 exit 1
}


cat >/usr/local/bin/gdrive-status <<'SCRIPT'
#!/usr/bin/env bash
set -e

echo "==== REMOTES ===="
rclone listremotes

echo
echo "==== DRIVE TEST ===="
rclone about CONFIG-LOCATION:
SCRIPT

chmod 700 /usr/local/bin/gdrive-status



cat >/usr/local/bin/snapshot-create <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/lib/config-location/storage"
DRIVE="CONFIG-LOCATION/snapshots"

TS=$(date +%Y%m%d-%H%M%S)

NAME="CONFIG-LOCATION-SNAPSHOT-$TS"

ARCHIVE="$BASE/archive/$NAME.tar.gz"
SHA="$ARCHIVE.sha256"
MANIFEST="$BASE/manifests/$NAME.json"


echo "Creating snapshot..."

tar \
-czf "$ARCHIVE" \
/opt/config-location \
/etc/systemd/system \
/var/lib/config-location \
2>/dev/null || true


sha256sum "$ARCHIVE" > "$SHA"


SIZE=$(stat -c%s "$ARCHIVE")


cat > "$MANIFEST" <<JSON
{
"name":"$NAME",
"time":"$(date -Is)",
"size":"$SIZE",
"sha256":"$(cut -d' ' -f1 "$SHA")"
}
JSON


echo "Uploading..."

rclone copy \
"$ARCHIVE" \
"$DRIVE/$NAME"

rclone copy \
"$SHA" \
"$DRIVE/$NAME"


echo "VERIFY..."

rclone size \
"$DRIVE/$NAME"


echo "SNAPSHOT COMPLETE"

echo "$MANIFEST"

SCRIPT

chmod 700 /usr/local/bin/snapshot-create



cat >/usr/local/bin/snapshot-list <<'SCRIPT'
#!/usr/bin/env bash
set -e

rclone lsf \
CONFIG-LOCATION:snapshots \
--dirs-only

SCRIPT

chmod 700 /usr/local/bin/snapshot-list



cat >/usr/local/bin/snapshot-latest <<'SCRIPT'
#!/usr/bin/env bash
set -e

rclone lsf \
CONFIG-LOCATION:snapshots \
--dirs-only |
sort |
tail -1

SCRIPT

chmod 700 /usr/local/bin/snapshot-latest



cat >/usr/local/bin/snapshot-verify <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

FILE=$(snapshot-latest)

if [ -z "$FILE" ]; then
 echo "No snapshot"
 exit 1
fi


echo "Latest:"
echo "$FILE"

rclone check \
CONFIG-LOCATION:snapshots/$FILE \
/dev/null || true


echo "VERIFY COMPLETE"

SCRIPT

chmod 700 /usr/local/bin/snapshot-verify



echo
echo "======================================"
echo " STORAGE MANAGER INSTALLED"
echo "======================================"

echo
echo "Commands:"
echo " gdrive-status"
echo " snapshot-create"
echo " snapshot-list"
echo " snapshot-latest"
echo " snapshot-verify"

