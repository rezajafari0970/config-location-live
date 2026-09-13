#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase2-control-plane"

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
echo " CONFIG LOCATION PHASE 2"
echo " CONTROL PLANE API"
echo "================================================"


echo
echo "START:"
date -Is


echo
echo "HOST:"
hostname


################################################
# Backup
################################################

echo
echo "========== BACKUP =========="


cp -a \
"$PROJECT/app/panel" \
"$BACKUP/panel" \
|| fail "panel backup failed"


################################################
# Detect Panel
################################################

echo
echo "========== DETECT PANEL =========="


SERVER_FILE=$(find "$PROJECT/app" \
-name "server.py" \
-type f \
| head -n 1)


if [ -z "$SERVER_FILE" ]; then
    fail "server.py not found"
else
    echo "SERVER:"
    echo "$SERVER_FILE"
fi



################################################
# Create Control Module
################################################

echo
echo "========== CREATE CONTROL MODULE =========="


mkdir -p \
"$PROJECT/app/control"


cat > "$PROJECT/app/control/__init__.py" <<'PY'
PY



cat > "$PROJECT/app/control/executor.py" <<'PY'
from __future__ import annotations

import asyncio
import subprocess


ALLOWED_SERVICES = {
    "config-location-panel.service",
}


async def service_status(service: str):

    if service not in ALLOWED_SERVICES:
        raise ValueError(
            "service not allowed"
        )

    proc = await asyncio.create_subprocess_exec(
        "systemctl",
        "is-active",
        service,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    out, err = await proc.communicate()

    return {
        "service": service,
        "active":
            out.decode().strip(),
        "code":
            proc.returncode,
    }



async def restart_service(service: str):

    if service not in ALLOWED_SERVICES:
        raise ValueError(
            "service not allowed"
        )


    proc = await asyncio.create_subprocess_exec(
        "systemctl",
        "restart",
        service,
    )

    code = await proc.wait()


    return {
        "service": service,
        "restarted": True,
        "code": code,
    }
PY



cat > "$PROJECT/app/control/api.py" <<'PY'
from __future__ import annotations


from aiohttp import web

from app.control.executor import (
    service_status,
    restart_service,
)



async def control_status(request):

    result = await service_status(
        "config-location-panel.service"
    )

    return web.json_response(
        {
            "ok": True,
            "services":[
                result
            ]
        }
    )



async def control_restart(request):

    data = await request.json()

    service = data.get(
        "service"
    )


    result = await restart_service(
        service
    )


    return web.json_response(
        {
            "ok": True,
            "result": result
        }
    )



async def system_info(request):

    import shutil
    import os


    total, used, free = shutil.disk_usage("/")


    return web.json_response(
        {
            "ok": True,

            "disk":{
                "total": total,
                "used": used,
                "free": free
            },

            "cpu":{
                "load":
                os.getloadavg()
            }
        }
    )



def install_control_routes(app):

    if getattr(
        app,
        "_control_routes",
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
        "/api/control/system",
        system_info
    )


    app._control_routes=True
PY



################################################
# Patch Panel
################################################

echo
echo "========== PATCH PANEL =========="


if ! grep -q "install_control_routes" "$SERVER_FILE"; then


python3 - "$SERVER_FILE" <<'PY'

import sys
from pathlib import Path

p=Path(sys.argv[1])

t=p.read_text(
    encoding="utf-8"
)


if "app.control.api" not in t:

    t=t.replace(
        "from aiohttp import web",
        "from aiohttp import web\nfrom app.control.api import install_control_routes",
        1
    )


marker="def create_app"

idx=t.find(marker)

if idx==-1:
    raise SystemExit(
        "create_app not found"
    )


# inject near end before return app
pos=t.find(
    "return app",
    idx
)

if pos!=-1:

    t=t[:pos]+(
        "install_control_routes(app)\n\n"
    )+t[pos:]


p.write_text(
    t,
    encoding="utf-8"
)

PY

fi



################################################
# Tests
################################################

echo
echo "========== TEST =========="


cd "$PROJECT"


PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
"$PROJECT/app/control/api.py" \
"$PROJECT/app/control/executor.py" \
"$SERVER_FILE" \
|| fail "compile failed"



echo "COMPILE_OK"



################################################
# Restart
################################################

echo
echo "========== RESTART PANEL =========="


systemctl restart \
config-location-panel.service \
|| fail "panel restart failed"


sleep 3


systemctl is-active \
config-location-panel.service \
|| fail "panel inactive"



################################################
# API TEST
################################################

echo
echo "========== API TEST =========="


curl -I \
http://127.0.0.1:4040/api/control/status \
|| fail "control api failed"



################################################
# Report
################################################


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



################################################
# Git Sync
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
echo "================================================"
echo " PHASE 2 COMPLETE"
echo "================================================"


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

