#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase2-pass3-control-hardening"

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


exec > >(tee "$LOG") 2>&1


RESULT="SUCCESS"
ERRORS=""


fail()
{
    RESULT="FAILED"
    ERRORS="${ERRORS}\n$1"
    echo "ERROR: $1"
}


echo "================================================"
echo " PHASE 2 PASS 3"
echo " CONTROL PLANE HARDENING"
echo "================================================"


echo
echo "START:"
date -Is


echo
echo "HOST:"
hostname



################################################
# BACKUP
################################################

echo
echo "========== BACKUP =========="


cp -a \
"$PROJECT/app/control" \
"$BACKUP/control" \
2>/dev/null || true


cp -a \
"$PROJECT/app/panel/server.py" \
"$BACKUP/server.py"



################################################
# POLICY
################################################

echo
echo "========== POLICY =========="


mkdir -p /etc/config-location


cat > /etc/config-location/control-policy.json <<'JSON'
{
  "allowed_services": [
    "config-location-panel.service"
  ],

  "allowed_actions": [
    "status",
    "restart",
    "system"
  ]
}
JSON



chmod 0640 \
/etc/config-location/control-policy.json



################################################
# TOKEN
################################################

echo
echo "========== TOKEN =========="


if [ ! -f /etc/config-location/control-token ]; then

    openssl rand -hex 32 \
    > /etc/config-location/control-token

    chmod 0640 \
    /etc/config-location/control-token

fi



################################################
# CONTROL MODULE
################################################

echo
echo "========== UPDATE CONTROL MODULE =========="


mkdir -p \
"$PROJECT/app/control"



cat > "$PROJECT/app/control/security.py" <<'PY'
from __future__ import annotations

import json
from pathlib import Path


POLICY = Path(
    "/etc/config-location/control-policy.json"
)

TOKEN = Path(
    "/etc/config-location/control-token"
)


def get_policy():

    if not POLICY.exists():
        return {}

    return json.loads(
        POLICY.read_text()
    )


def check_action(action):

    policy=get_policy()

    return (
        action
        in
        policy.get(
            "allowed_actions",
            []
        )
    )


def check_token(value):

    if not TOKEN.exists():
        return False

    return (
        value.strip()
        ==
        TOKEN.read_text()
        .strip()
    )

PY



cat > "$PROJECT/app/control/audit.py" <<'PY'
from __future__ import annotations

from pathlib import Path
from datetime import datetime


LOG_DIR = Path(
    "/var/log/config-location/control"
)


def audit(
    action,
    result,
    detail=""
):

    LOG_DIR.mkdir(
        parents=True,
        exist_ok=True
    )

    file = (
        LOG_DIR /
        datetime.utcnow()
        .strftime("%Y-%m-%d")
        + ".log"
    )

    with file.open(
        "a",
        encoding="utf-8"
    ) as f:

        f.write(
            "\n".join(
                [
                    "================",
                    datetime.utcnow()
                    .isoformat(),
                    f"ACTION={action}",
                    f"RESULT={result}",
                    f"DETAIL={detail}",
                    ""
                ]
            )
        )

PY



cat > "$PROJECT/app/control/api.py" <<'PY'
from __future__ import annotations


from aiohttp import web


from app.control.executor import (
    service_status,
    restart_service,
)


from app.control.security import (
    check_token,
    check_action,
)


from app.control.audit import audit



def auth(request):

    token = request.headers.get(
        "X-Control-Token",
        ""
    )

    return check_token(token)



async def control_status(request):

    if not auth(request):
        return web.json_response(
            {
                "error":"unauthorized"
            },
            status=401
        )


    if not check_action(
        "status"
    ):
        return web.json_response(
            {
                "error":"forbidden"
            },
            status=403
        )


    result = await service_status(
        "config-location-panel.service"
    )

    audit(
        "status",
        "success"
    )


    return web.json_response(
        {
            "ok":True,
            "services":[result]
        }
    )



async def control_restart(request):

    if not auth(request):
        return web.json_response(
            {
                "error":"unauthorized"
            },
            status=401
        )


    if not check_action(
        "restart"
    ):
        return web.json_response(
            {
                "error":"forbidden"
            },
            status=403
        )


    body = await request.json()

    result = await restart_service(
        body.get("service")
    )


    audit(
        "restart",
        "success",
        str(result)
    )


    return web.json_response(
        {
            "ok":True,
            "result":result
        }
    )



async def resources(request):

    import shutil
    import os


    total,used,free = shutil.disk_usage("/")


    return web.json_response(
        {
            "disk":{
                "total":total,
                "used":used,
                "free":free
            },

            "load":
                os.getloadavg()
        }
    )



def install_control_routes(app):

    if getattr(
        app,
        "_control_hardened",
        False
    ):
        return


    app.router.add_get(
        "/api/control/status",
        control_status
    )


    app.router.add_post(
        "/api/control/restart",
        control_restart
    )


    app.router.add_get(
        "/api/control/resources",
        resources
    )


    app._control_hardened=True

PY



################################################
# TEST
################################################

echo
echo "========== COMPILE =========="


cd "$PROJECT"


PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
app/control/*.py \
|| fail "compile failed"


echo "COMPILE_OK"



echo
echo "========== IMPORT TEST =========="


PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-c "
from app.control.api import install_control_routes
print('CONTROL_IMPORT_OK')
" \
|| fail "import failed"



################################################
# RESTART
################################################

echo
echo "========== PANEL RESTART =========="


systemctl restart \
config-location-panel.service \
|| fail "restart failed"


sleep 3


systemctl is-active \
config-location-panel.service \
|| fail "panel inactive"



################################################
# REPORT
################################################

cat > "$REPORT" <<REPORT

CONFIG LOCATION REPORT

Phase:
$PHASE

Result:
$RESULT

Time:
$(date -Is)

Backup:
$BACKUP

Log:
$LOG

Errors:
$ERRORS

REPORT



################################################
# GIT SYNC
################################################

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
echo " PHASE COMPLETE"
echo "=============================================="


echo "RESULT:"
echo "$RESULT"


echo "LOG:"
echo "$LOG"


echo "REPORT:"
echo "$REPORT"



if [ "$RESULT" != "SUCCESS" ]; then
    exit 1
fi

