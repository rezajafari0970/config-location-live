#!/bin/bash
set -e

echo "=== PHASE 1 PASS 2 FIX ==="

echo "[1] Fix runtime directory"

mkdir -p /run/config-location

chown configloc:configloc /run/config-location

chmod 0750 /run/config-location


echo "[2] Create tmpfiles rule"

cat > /etc/tmpfiles.d/config-location.conf <<EOT
d /run/config-location 0750 configloc configloc -
EOT


systemd-tmpfiles --create /etc/tmpfiles.d/config-location.conf


echo "[3] Permission test"

sudo -u configloc bash -c '
touch /run/config-location/test.lock
rm -f /run/config-location/test.lock
echo LOCK_PERMISSION_OK
'


echo "[4] Restart panel"

systemctl restart config-location-panel.service

sleep 3


echo "[5] Panel status"

systemctl is-active config-location-panel.service


echo "[6] Settings route"

curl -I http://127.0.0.1:4040/settings || true


echo "=== PASS2 COMPLETE ==="
