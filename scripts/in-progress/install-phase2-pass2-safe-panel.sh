#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase2-pass2-safe-panel"

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



echo "=============================================="
echo " PHASE 2 PASS 2"
echo " SAFE PANEL INTEGRATION"
echo "=============================================="


echo
echo "START:"
date -Is


################################################
# BACKUP CURRENT
################################################

echo
echo "========== BACKUP =========="


cp -a \
"$PROJECT/app/panel/server.py" \
"$BACKUP/server.py.current"



################################################
# RESTORE PREVIOUS SAFE VERSION
################################################

echo
echo "========== RESTORE CHECK =========="


LATEST_BACKUP=$(find /root/3245 \
-name "phase2-control-plane-backup-*" \
-type d \
| sort \
| tail -n 1 || true)


if [ -n "$LATEST_BACKUP" ] && \
[ -f "$LATEST_BACKUP/panel/server.py" ]; then

    echo "Restoring:"
    echo "$LATEST_BACKUP"

    cp \
    "$LATEST_BACKUP/panel/server.py" \
    "$PROJECT/app/panel/server.py"

else

    echo "No Phase2 backup restore needed"

fi



################################################
# CREATE CONTROL MODULE IF MISSING
################################################

echo
echo "========== CONTROL MODULE =========="


mkdir -p \
"$PROJECT/app/control"


cat > "$PROJECT/app/control/__init__.py" <<'PY'
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
            "services":[result]
        }
    )


async def control_restart(request):

    body = await request.json()

    result = await restart_service(
        body.get("service")
    )

    return web.json_response(
        {
            "ok": True,
            "result": result
        }
    )


def install_control_routes(app):

    if getattr(
        app,
        "_control_installed",
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


    app._control_installed=True

PY


cat > "$PROJECT/app/control/executor.py" <<'PY'
from __future__ import annotations

import asyncio


ALLOWED_SERVICES = {
    "config-location-panel.service",
}


async def service_status(service):

    if service not in ALLOWED_SERVICES:
        raise ValueError(
            "service not allowed"
        )


    proc = await asyncio.create_subprocess_exec(
        "systemctl",
        "is-active",
        service,
        stdout=asyncio.subprocess.PIPE,
    )

    out,_ = await proc.communicate()

    return {
        "service":service,
        "state":
            out.decode().strip(),
    }



async def restart_service(service):

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
        "service":service,
        "code":code
    }

PY



################################################
# SAFE PATCH
################################################

echo
echo "========== SAFE PATCH =========="


cd "$PROJECT"


PYTHONPATH="$PROJECT" python3 <<'PY'

from pathlib import Path
import ast

path = Path(
"app/panel/server.py"
)


text = path.read_text(
encoding="utf-8"
)


tree = ast.parse(text)


create_found=False
return_found=False


for node in ast.walk(tree):

    if isinstance(node, ast.FunctionDef):

        if node.name=="create_app":

            create_found=True

            for child in ast.walk(node):

                if isinstance(child, ast.Return):

                    return_found=True


if not create_found:
    raise SystemExit(
        "create_app not found"
    )


if not return_found:
    raise SystemExit(
        "create_app return not found"
    )


print(
"SAFE_HOOK_FOUND"
)

PY



################################################
# INSERT USING MARKER
################################################

python3 <<'PY'

from pathlib import Path

p=Path(
"app/panel/server.py"
)

t=p.read_text(
encoding="utf-8"
)


if "install_control_routes" not in t:

    t=t.replace(
        "return app",
        "install_control_routes(app)\n\n    return app",
        1
    )


    if "from app.control.api import" not in t:

        t=t.replace(
            "from aiohttp import web",
            "from aiohttp import web\nfrom app.control.api import install_control_routes",
            1
        )


p.write_text(
t,
encoding="utf-8"
)

PY



################################################
# COMPILE BEFORE RESTART
################################################

echo
echo "========== COMPILE =========="


PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" \
-m py_compile \
"$PROJECT/app/panel/server.py" \
"$PROJECT/app/control/api.py" \
"$PROJECT/app/control/executor.py"


echo "COMPILE_OK"



################################################
# CREATE APP TEST
################################################

echo
echo "========== APP TEST =========="


PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'

from app.panel.server import create_app

app=create_app()

routes={
r.resource.canonical
for r in app.router.routes()
}

assert "/api/control/status" in routes
assert "/api/control/restart" in routes

print(
"CONTROL_ROUTES_OK"
)

PY



################################################
# RESTART
################################################

echo
echo "========== RESTART PANEL =========="


systemctl restart \
config-location-panel.service


sleep 3


systemctl is-active \
config-location-panel.service



################################################
# HTTP TEST
################################################

echo
echo "========== HTTP TEST =========="


curl -I \
http://127.0.0.1:4040/api/control/status \
|| fail "control status failed"



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
# GIT
################################################

echo
echo "========== GIT SYNC =========="


cd "$LOG_REPO"

git add .

git commit \
-m "Phase execution $PHASE $TS" \
|| true

git push origin main || true



echo
echo "=============================================="
echo " FINISHED"
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

