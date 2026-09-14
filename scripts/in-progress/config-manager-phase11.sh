#!/usr/bin/env bash

set -euo pipefail


PROJECT="/opt/config-manager"
USER="configmanager"
PORT="9090"


echo "======================================"
echo " CONFIG MANAGER"
echo " PHASE 1.1 FIRST WORKING SYSTEM V1"
echo "======================================"

date


if ! id "$USER" >/dev/null 2>&1
then
    useradd -r -m -d "$PROJECT" -s /usr/sbin/nologin "$USER"
fi


echo "[1] Create structure"


mkdir -p \
"$PROJECT/backend/app/dashboard" \
"$PROJECT/backend/app/sources" \
"$PROJECT/backend/app/fetcher" \
"$PROJECT/backend/app/storage" \
"$PROJECT/backend/app/templates" \
"$PROJECT/backend/app/static" \
"$PROJECT/storage/sources" \
"$PROJECT/storage/configs" \
"$PROJECT/storage/logs" \
"$PROJECT/storage/reports" \
"$PROJECT/storage/backup" \
"$PROJECT/workers" \
"$PROJECT/systemd"


echo "[2] Python environment"


if [ ! -d "$PROJECT/venv" ]
then
    python3 -m venv "$PROJECT/venv"
fi


source "$PROJECT/venv/bin/activate"


pip install --upgrade pip


pip install \
fastapi \
uvicorn[standard] \
jinja2 \
aiofiles \
httpx \
python-multipart


deactivate



echo "[3] Storage"



cat > "$PROJECT/backend/app/storage/store.py" <<'PY'
import json
from pathlib import Path


BASE = Path("/opt/config-manager/storage")


def save_sources(data):
    path = BASE / "sources/sources.json"
    path.parent.mkdir(parents=True, exist_ok=True)

    path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False),
        encoding="utf-8"
    )


def load_sources():

    path = BASE / "sources/sources.json"

    if not path.exists():
        return []

    return json.loads(
        path.read_text(encoding="utf-8")
    )
PY



echo "[4] Fetch worker"



cat > "$PROJECT/workers/fetch_worker.py" <<'PY'
import asyncio
import httpx
from datetime import datetime
from pathlib import Path
import json


BASE = Path("/opt/config-manager/storage")


async def run():

    src = BASE / "sources/sources.json"

    if not src.exists():
        return


    sources = json.loads(
        src.read_text()
    )


    async with httpx.AsyncClient(timeout=20) as client:

        for url in sources:

            try:

                r = await client.get(url)

                name = datetime.now().strftime(
                    "%Y%m%d-%H%M%S"
                )

                out = BASE / "configs" / f"{name}.txt"

                out.write_text(
                    r.text,
                    encoding="utf-8"
                )


            except Exception as e:

                log = BASE / "logs/worker.log"

                log.write_text(
                    str(e),
                    encoding="utf-8"
                )


if __name__ == "__main__":

    asyncio.run(run())
PY



echo "[5] FastAPI Panel"



cat > "$PROJECT/backend/app/main.py" <<'PY'
from fastapi import FastAPI, Form
from fastapi.responses import HTMLResponse
from pathlib import Path

from storage.store import (
    load_sources,
    save_sources
)


app = FastAPI(
    title="Config Manager"
)



@app.get("/", response_class=HTMLResponse)
def home():

    sources = load_sources()

    return f"""

<h1>Config Manager</h1>

<h3>Status: Running</h3>

<p>Sources: {len(sources)}</p>

<a href='/sources'>Sources</a>

"""



@app.get("/sources", response_class=HTMLResponse)
def sources():

    items = load_sources()

    html = """

<h2>Sources</h2>

<form method="post">

<input name="url" placeholder="Source URL">

<button>Add</button>

</form>

<hr>

"""

    for x in items:

        html += f"<p>{x}</p>"


    return html



@app.post("/sources")
def add_source(url:str=Form(...)):

    data = load_sources()

    data.append(url)

    save_sources(data)

    return {
        "status":"saved",
        "url":url
    }



@app.get("/health")
def health():

    return {
        "status":"healthy",
        "project":"Config Manager"
    }
PY



echo "[6] Service"



cat > "$PROJECT/systemd/config-manager.service" <<SERVICE
[Unit]
Description=Config Manager V1

After=network.target


[Service]

User=$USER

WorkingDirectory=$PROJECT/backend/app

ExecStart=$PROJECT/venv/bin/uvicorn main:app --host 0.0.0.0 --port $PORT


Restart=always


[Install]

WantedBy=multi-user.target
SERVICE



cp "$PROJECT/systemd/config-manager.service" \
/etc/systemd/system/config-manager.service



systemctl daemon-reload

systemctl enable config-manager

systemctl restart config-manager



echo "[7] Permissions"


chown -R "$USER:$USER" "$PROJECT"



echo "[8] Test"



sleep 3


curl -s \
http://127.0.0.1:$PORT/health \
> "$PROJECT/storage/reports/health-test.json"



cat "$PROJECT/storage/reports/health-test.json"



echo


echo "======================================"
echo " PHASE 1.1 COMPLETE"
echo " PANEL PORT: $PORT"
echo "======================================"

