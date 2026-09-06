#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase1-pass2"

PROJECT="/opt/config-location"
LOG_REPO="/root/project-log"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"

RUN_DIR="$LOG_REPO/executions/$DATE"
REPORT_DIR="$LOG_REPO/reports"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"

BACKUP="/root/3245/${PHASE}-backup-${TS}"

mkdir -p \
"$RUN_DIR" \
"$REPORT_DIR" \
"$BACKUP"


exec > >(tee -a "$LOG") 2>&1


echo "=============================================="
echo " CONFIG LOCATION PHASE 1 PASS 2"
echo "=============================================="

echo
echo "START:"
date -Is

echo
echo "HOST:"
hostname


echo
echo "RESOURCE BEFORE"
df -h /
free -h
uptime


echo
echo "========== BACKUP =========="


cp -a \
/run/config-location \
"$BACKUP/runtime-before" \
2>/dev/null || true


cp -a \
/etc/tmpfiles.d/config-location.conf \
"$BACKUP/" \
2>/dev/null || true



echo
echo "========== FIX RUNTIME DIRECTORY =========="


mkdir -p /run/config-location


chown \
configloc:configloc \
/run/config-location


chmod 0750 \
/run/config-location



echo
echo "========== TMPFILES =========="


cat > /etc/tmpfiles.d/config-location.conf <<EOT
d /run/config-location 0750 configloc configloc -
EOT


systemd-tmpfiles \
--create \
/etc/tmpfiles.d/config-location.conf



echo
echo "========== PERMISSION TEST =========="


sudo -u configloc bash -c '

touch /run/config-location/test.lock

echo LOCK_CREATE_OK

rm -f /run/config-location/test.lock

echo LOCK_REMOVE_OK

'


echo
echo "========== SETTINGS TEST =========="


"$PROJECT/venv/bin/python" - <<PY

from pathlib import Path
import os

p = Path(
"/run/config-location/settings.lock"
)

fd = os.open(
str(p),
os.O_CREAT | os.O_RDWR,
0o600
)

os.close(fd)

assert p.exists()

p.unlink()

print(
"SETTINGS_LOCK_TEST_OK"
)

PY



echo
echo "========== SETTINGS FILE =========="


test -f \
/var/lib/config-location/settings/settings.json


echo SETTINGS_FILE_OK



"$PROJECT/venv/bin/python" - <<PY

from app.settings.engine import (
get_settings_status
)

s=get_settings_status()

print(
"REVISION=",
s["revision"]
)

print(
"CHECKSUM=",
s["checksum"]
)

assert len(
s["checksum"]
)==64

print(
"SETTINGS_STATUS_OK"
)

PY



echo
echo "========== PANEL =========="


systemctl restart \
config-location-panel.service


sleep 3


systemctl is-active \
config-location-panel.service



echo
echo "========== HTTP TEST =========="


curl -I \
http://127.0.0.1:4040/settings \
|| true


curl -I \
http://127.0.0.1:4040/api/settings \
|| true



echo
echo "========== RESOURCE AFTER =========="

df -h /
free -h
uptime



cat > "$REPORT" <<REPORT

CONFIG LOCATION REPORT

Phase:
$PHASE

Result:
SUCCESS

Time:
$(date -Is)

Host:
$(hostname)

Backup:
$BACKUP

Log:
$LOG

Tests:
- runtime directory
- tmpfiles
- permission
- settings lock
- settings status
- panel restart
- HTTP routes

REPORT



echo
echo "========== GIT SYNC =========="


cd "$LOG_REPO"


git add .


git commit \
-m "Phase execution $PHASE $TS" \
|| true


git push origin main



echo
echo "=============================================="
echo " PHASE 1 PASS 2 COMPLETE"
echo "=============================================="

echo
echo "LOG:"
echo "$LOG"

echo
echo "REPORT:"
echo "$REPORT"

