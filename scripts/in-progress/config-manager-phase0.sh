#!/usr/bin/env bash

set -euo pipefail

PROJECT="/opt/config-manager"

echo "======================================"
echo " CONFIG MANAGER PHASE 0 "
echo " FOUNDATION INSTALL "
echo "======================================"


echo "[1] Creating project structure"


mkdir -p "$PROJECT"

mkdir -p "$PROJECT/backend/app/core"
mkdir -p "$PROJECT/backend/app/storage"
mkdir -p "$PROJECT/backend/app/api"

mkdir -p "$PROJECT/frontend/templates"
mkdir -p "$PROJECT/frontend/static"
mkdir -p "$PROJECT/frontend/assets"

mkdir -p "$PROJECT/storage/sources"
mkdir -p "$PROJECT/storage/configs"
mkdir -p "$PROJECT/storage/logs"
mkdir -p "$PROJECT/storage/errors"
mkdir -p "$PROJECT/storage/backup"

mkdir -p "$PROJECT/workers"
mkdir -p "$PROJECT/tests"
mkdir -p "$PROJECT/docs"
mkdir -p "$PROJECT/installer"



echo "[2] Creating Python environment"


cd "$PROJECT"

PYTHON_BIN=$(command -v python3)

if [ ! -d "venv" ]; then
    "$PYTHON_BIN" -m venv venv
fi


source "$PROJECT/venv/bin/activate"



echo "[3] Installing backend packages"


pip install --upgrade pip

pip install \
fastapi \
uvicorn \
jinja2 \
aiofiles \
httpx \
pydantic


pip freeze > "$PROJECT/backend/requirements-lock.txt"


deactivate



echo "[4] Creating core modules"



cat > "$PROJECT/backend/app/core/paths.py" <<'PY'
from pathlib import Path


BASE_DIR = Path("/opt/config-manager")

STORAGE_DIR = BASE_DIR / "storage"

SOURCES_DIR = STORAGE_DIR / "sources"

CONFIGS_DIR = STORAGE_DIR / "configs"

LOGS_DIR = STORAGE_DIR / "logs"

ERRORS_DIR = STORAGE_DIR / "errors"

BACKUP_DIR = STORAGE_DIR / "backup"
PY



cat > "$PROJECT/backend/app/core/config.py" <<'PY'
PROJECT_NAME = "Config Manager"

VERSION = "0.1.0"

ENVIRONMENT = "development"
PY



echo "[5] Creating File Storage Engine"



cat > "$PROJECT/backend/app/storage/file_storage.py" <<'PY'
import json
from pathlib import Path


class FileStorage:


    def save_json(self, path: Path, data: dict):

        path.parent.mkdir(
            parents=True,
            exist_ok=True
        )

        with open(
            path,
            "w",
            encoding="utf-8"
        ) as file:

            json.dump(
                data,
                file,
                indent=2,
                ensure_ascii=False
            )



    def load_json(self, path: Path):

        if not path.exists():
            return None


        with open(
            path,
            encoding="utf-8"
        ) as file:

            return json.load(file)
PY



echo "[6] Creating FastAPI Core"



cat > "$PROJECT/backend/app/main.py" <<'PY'
from fastapi import FastAPI


app = FastAPI(
    title="Config Manager",
    version="0.1.0"
)


@app.get("/")
def health():

    return {
        "project": "Config Manager",
        "phase": "Foundation",
        "status": "running"
    }
PY



echo "[7] Creating documentation"



cat > "$PROJECT/docs/PROJECT_SPEC.md" <<'DOC'
# Config Manager

## Technology

Backend:
Python + FastAPI

Frontend:
HTML CSS JavaScript TailwindCSS

Storage:
File Based

Database:
None


## Architecture

Modular
Automatic
Independent Workers


## Phase

0 - Foundation
DOC



cat > "$PROJECT/docs/ARCHITECTURE.md" <<'DOC'
# Architecture


Panel

↓

FastAPI Core

↓

Modules

↓

Workers

↓

File Storage
DOC



cat > "$PROJECT/docs/CHANGELOG.md" <<'DOC'
# CHANGELOG


## 0.1.0

Initial foundation created.
DOC



echo "[8] Creating test file"



cat > "$PROJECT/tests/test_phase0.txt" <<'TXT'
Config Manager Phase 0 OK
TXT



chmod -R 755 "$PROJECT"


echo
echo "======================================"
echo " PHASE 0 COMPLETE "
echo "======================================"

