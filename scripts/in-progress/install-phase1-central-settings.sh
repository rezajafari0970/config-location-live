#!/usr/bin/env bash
set -Eeuo pipefail


############################################################
# CONFIG LOCATION
# PHASE 1 - CENTRAL SETTINGS ENGINE
# SELF LOGGING + GITHUB SYNC
############################################################


PHASE="phase1-central-settings"

PROJECT="/opt/config-location"
LOG_REPO="/root/project-log"

DATE="$(date +%Y-%m-%d)"
TS="$(date +%Y%m%d-%H%M%S)"

RUN_DIR="$LOG_REPO/executions/$DATE"
REPORT_DIR="$LOG_REPO/reports"

LOG_FILE="$RUN_DIR/${PHASE}-${TS}.log"
REPORT_FILE="$REPORT_DIR/${PHASE}-${TS}.txt"

BACKUP="/root/3245/${PHASE}-backup-${TS}"


mkdir -p \
"$RUN_DIR" \
"$REPORT_DIR" \
"$BACKUP"


############################################################
# LOGGING
############################################################

exec > >(tee -a "$LOG_FILE") 2>&1


START="$(date -Is)"


echo "================================================="
echo " CONFIG LOCATION PHASE EXECUTION"
echo "================================================="

echo
echo "PHASE:"
echo "$PHASE"

echo
echo "START:"
echo "$START"

echo
echo "HOST:"
hostname

echo
echo "USER:"
whoami


############################################################
# RESOURCE BEFORE
############################################################

echo
echo "========== RESOURCE BEFORE =========="

df -h /

free -h

uptime


############################################################
# GIT CHECK
############################################################

if [ ! -d "$LOG_REPO/.git" ]; then
    echo "ERROR: Project-log repository missing"
    exit 1
fi


############################################################
# BACKUP
############################################################

echo
echo "========== BACKUP =========="


cp -a \
"$PROJECT/app/panel/server.py" \
"$BACKUP/"


if [ -d "$PROJECT/app/settings" ]; then
    cp -a \
    "$PROJECT/app/settings" \
    "$BACKUP/" || true
fi


############################################################
# INSTALL SETTINGS ENGINE
############################################################

echo
echo "========== INSTALL PHASE1 =========="


mkdir -p \
"$PROJECT/app/settings" \
"/var/lib/config-location/settings/history"



cat > "$PROJECT/app/settings/__init__.py" <<'PY'
from app.settings.engine import (
    get_settings,
    update_settings,
    get_settings_status,
)

__all__ = [
    "get_settings",
    "update_settings",
    "get_settings_status",
]
PY


echo "Settings module prepared"


############################################################
# INIT SETTINGS
############################################################


"$PROJECT/venv/bin/python" - <<'PY'

from pathlib import Path
import json
import hashlib
import time


path = Path(
"/var/lib/config-location/settings/settings.json"
)

path.parent.mkdir(
parents=True,
exist_ok=True
)


if not path.exists():

    data = {

        "schema_version":1,

        "meta":{
            "revision":1,
            "created_at":time.time(),
            "updated_at":time.time()
        },

        "source_intelligence":{
            "healthy_window_hours":12
        },

        "health_retest":{
            "interval_seconds":300
        },

        "config_lifetime":{
            "max_age_hours":48
        },

        "cleanup":{
            "retention_days":7
        },

        "publish":{
            "panel_port":4040,
            "public_port":80
        },

        "country":{
            "unknown":"Unknown",
            "remark":"{flag} {country}"
        }

    }


    raw=json.dumps(
        data,
        indent=2,
        ensure_ascii=False
    )

    path.write_text(
        raw,
        encoding="utf-8"
    )


print("CENTRAL_SETTINGS_CREATED")

print(
"SHA256:",
hashlib.sha256(
path.read_bytes()
).hexdigest()
)

PY


############################################################
# TEST
############################################################


echo
echo "========== TEST =========="


"$PROJECT/venv/bin/python" -m py_compile \
"$PROJECT/app/settings/__init__.py"


echo "PYTHON_COMPILE_OK"



test -f \
/var/lib/config-location/settings/settings.json


echo "SETTINGS_FILE_OK"



############################################################
# PANEL RESTART
############################################################


echo
echo "========== PANEL =========="


systemctl restart \
config-location-panel.service


sleep 3


systemctl is-active \
config-location-panel.service



############################################################
# RESOURCE AFTER
############################################################


echo
echo "========== RESOURCE AFTER =========="

df -h /

free -h

uptime



############################################################
# REPORT
############################################################


cat > "$REPORT_FILE" <<REPORT

CONFIG LOCATION PHASE REPORT

Phase:
$PHASE

Start:
$START

End:
$(date -Is)

Host:
$(hostname)

Result:
SUCCESS

Settings:
 /var/lib/config-location/settings/settings.json

Backup:
$BACKUP

Log:
$LOG_FILE

REPORT



############################################################
# GIT SYNC
############################################################


echo
echo "========== GIT SYNC =========="


cd "$LOG_REPO"


git add .


git commit \
-m "Phase execution $PHASE $TS" \
|| true


git push origin main


############################################################
# FINAL
############################################################


echo
echo "================================================="
echo " PHASE COMPLETE"
echo "================================================="

echo
echo "LOG:"
echo "$LOG_FILE"

echo

echo "REPORT:"
echo "$REPORT_FILE"

echo

echo "GITHUB SYNC:"
echo "DONE"

