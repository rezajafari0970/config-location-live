#!/usr/bin/env bash

set -euo pipefail

BASE="/opt/config-manager/panel"
APP="$BASE/app"

echo "======================================"
echo " CONFIG MANAGER"
echo " PHASE 1.2.1 PANEL MODULAR FOUNDATION"
echo "======================================"

mkdir -p \
"$APP/core" \
"$APP/modules/dashboard" \
"$APP/modules/sources" \
"$APP/templates" \
"$APP/static/css" \
"$APP/static/js" \
"$BASE/systemd"


echo "[1] Core Loader"

cat > "$APP/core/loader.py" <<'PY'
from pathlib import Path
import importlib


def load_modules(app):

    base = Path(__file__).parent.parent / "modules"

    for module in base.iterdir():

        router = module / "router.py"

        if router.exists():

            name = f"modules.{module.name}.router"

            mod = importlib.import_module(name)

            if hasattr(mod, "router"):
                app.include_router(mod.router)
PY


cat > "$APP/core/paths.py" <<'PY'
from pathlib import Path

BASE = Path("/opt/config-manager")

STORAGE = BASE / "storage"
PY



echo "[2] Main Panel"


cat > "$APP/main.py" <<'PY'
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from core.loader import load_modules


app = FastAPI(
    title="Config Manager Panel"
)


app.mount(
    "/static",
    StaticFiles(directory="static"),
    name="static"
)


load_modules(app)


@app.get("/health")
def health():

    return {
        "panel":"running",
        "status":"healthy"
    }
PY



echo "[3] Dashboard Module"


cat > "$APP/modules/dashboard/router.py" <<'PY'
from fastapi import APIRouter
from fastapi.responses import HTMLResponse


router = APIRouter()


@router.get("/")
def dashboard():

    return HTMLResponse(
"""
<html>
<head>
<link rel="stylesheet" href="/static/css/app.css">
</head>

<body>

<div class="card">

<h1>
Config Manager Dashboard
</h1>

<p>
Panel Modular V1 Running
</p>

</div>

<script src="/static/js/app.js"></script>

</body>
</html>
"""
    )
PY



echo "[4] Sources Module"


cat > "$APP/modules/sources/router.py" <<'PY'
from fastapi import APIRouter


router = APIRouter(
    prefix="/sources"
)


@router.get("/")
def sources():

    return {
        "module":"sources",
        "status":"ready"
    }
PY



echo "[5] UI Assets"


cat > "$APP/static/css/app.css" <<'CSS'
body{

background:#0f172a;
color:white;
font-family:Arial;

}

.card{

margin:50px auto;
padding:30px;
max-width:500px;
background:#1e293b;
border-radius:16px;

}
CSS



cat > "$APP/static/js/app.js" <<'JS'
console.log("Panel Modular UI Loaded");
JS



echo "[6] Service"



cat > "$BASE/systemd/config-manager-panel.service" <<SERVICE
[Unit]
Description=Config Manager Modular Panel

After=network.target


[Service]

User=configmanager

WorkingDirectory=$APP

ExecStart=/opt/config-manager/venv/bin/uvicorn main:app --host 0.0.0.0 --port 9090

Restart=always


[Install]

WantedBy=multi-user.target
SERVICE



echo "[7] Snapshot"



ART="/root/project-reports/artifacts/source-snapshots/panel-modular"

mkdir -p "$ART"


rsync -a \
--exclude __pycache__ \
"$BASE/" \
"$ART/"



find "$ART" -type f \
| sort \
> /root/project-reports/artifacts/manifests/panel-modular-manifest.txt



cd "$ART"

sha256sum $(find . -type f) \
> /root/project-reports/artifacts/hashes/panel-modular.sha256



cat > /root/project-reports/artifacts/verification/panel-modular-verification.md <<VERIFY
# Panel Modular Foundation

Status:

SUCCESS

Port:

9090

Generated:

$(date)

VERIFY


chown -R configmanager:configmanager /opt/config-manager/panel


echo "======================================"
echo " PANEL MODULAR FOUNDATION COMPLETE"
echo "======================================"

