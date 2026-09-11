#!/usr/bin/env bash
set -uo pipefail

PHASE="phase1-pass2-v2"

PROJECT="/opt/config-location"
LOG_REPO="/root/project-log"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"

RUN_DIR="$LOG_REPO/executions/$DATE"
REPORT_DIR="$LOG_REPO/reports"
BACKUP="/root/3245/${PHASE}-backup-$TS"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"

mkdir -p \
"$RUN_DIR" \
"$REPORT_DIR" \
"$BACKUP"


exec > >(tee "$LOG") 2>&1


RESULT="SUCCESS"
ERRORS=""


fail()
{
    RESULT="FAILED"
    ERRORS="$ERRORS\n$1"
    echo "ERROR: $1"
}


echo "=============================================="
echo " CONFIG LOCATION PHASE 1 PASS 2 v2"
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
echo "========== RUNTIME DIRECTORY =========="

mkdir -p /run/config-location || fail "create runtime dir failed"

chown configloc:configloc \
/run/config-location \
|| fail "chown failed"

chmod 0750 \
/run/config-location \
|| fail "chmod failed"



echo
echo "========== TMPFILES =========="

cat > /etc/tmpfiles.d/config-location.conf <<EOT
d /run/config-location 0750 configloc configloc -
EOT


systemd-tmpfiles \
--create \
/etc/tmpfiles.d/config-location.conf \
|| fail "tmpfiles failed"



echo
echo "========== PERMISSION TEST =========="

sudo -u configloc bash -c '
touch /run/config-location/test.lock &&
echo LOCK_CREATE_OK &&
rm -f /run/config-location/test.lock &&
echo LOCK_REMOVE_OK
' || fail "permission test failed"



echo
echo "========== SETTINGS TEST =========="


cd "$PROJECT"


PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY' \
|| fail "settings python test failed"

from app.settings.engine import (
    get_settings_status
)

s=get_settings_status()

print("REVISION:",s["revision"])
print("CHECKSUM:",s["checksum"])

assert len(s["checksum"]) == 64

print("SETTINGS_STATUS_OK")

PY



echo
echo "========== SETTINGS FILE =========="

test -f \
/var/lib/config-location/settings/settings.json \
|| fail "settings file missing"


echo SETTINGS_FILE_OK



echo
echo "========== PANEL TEST =========="


systemctl restart \
config-location-panel.service \
|| fail "panel restart failed"


sleep 3


systemctl is-active \
config-location-panel.service \
|| fail "panel inactive"



echo
echo "HTTP TEST"


curl -I \
http://127.0.0.1:4040/settings \
|| fail "settings route failed"


curl -I \
http://127.0.0.1:4040/api/settings \
|| fail "api route failed"



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
$RESULT

Time:
$(date -Is)

Host:
$(hostname)

Backup:
$BACKUP

Log:
$LOG

Errors:
$ERRORS

REPORT



echo
echo "========== GIT SYNC =========="


cd "$LOG_REPO"


git add .


git commit \
-m "Phase execution $PHASE $TS" \
|| true


git push origin main \
|| true



echo
echo "=============================================="
echo " FINISHED"
echo "=============================================="

echo
echo "RESULT:"
echo "$RESULT"

echo
echo "LOG:"
echo "$LOG"

echo
echo "REPORT:"
echo "$REPORT"


if [ "$RESULT" != "SUCCESS" ]; then
    exit 1
fi

