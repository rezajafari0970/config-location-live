#!/usr/bin/env bash

set -euo pipefail


PROJECT="/opt/config-manager"


echo "======================================"
echo " CONFIG MANAGER PHASE 0.5"
echo " ENVIRONMENT PREPARATION"
echo "======================================"


echo "[1] System update"


apt update -y

apt upgrade -y



echo "[2] Base packages"


apt install -y \
curl \
wget \
git \
tree \
htop \
unzip \
zip \
ca-certificates \
build-essential \
software-properties-common \
pkg-config \
make \
gcc \
g++ \
nginx



echo "[3] Python setup"


apt install -y \
python3 \
python3-pip \
python3-venv \
python3-dev



python3 --version

pip3 --version



echo "[4] Node setup"


if ! command -v node >/dev/null 2>&1
then

curl -fsSL https://deb.nodesource.com/setup_22.x | bash -

apt install -y nodejs

fi



node -v

npm -v



echo "[5] Nginx"


systemctl enable nginx

systemctl restart nginx



echo "[6] Project structure"



mkdir -p "$PROJECT"


mkdir -p "$PROJECT/backend"

mkdir -p "$PROJECT/frontend"

mkdir -p "$PROJECT/docs"

mkdir -p "$PROJECT/storage"

mkdir -p "$PROJECT/tests"



echo "[7] Python virtual environment"



if [ ! -d "$PROJECT/venv" ]
then

python3 -m venv "$PROJECT/venv"

fi



source "$PROJECT/venv/bin/activate"



pip install --upgrade pip



echo "[8] Backend packages"



pip install \
fastapi \
uvicorn[standard] \
jinja2 \
aiofiles \
httpx \
pydantic \
python-multipart \
pytest \
pytest-asyncio \
ruff \
black



pip freeze > "$PROJECT/backend-requirements-lock.txt"



deactivate



echo "[9] Frontend Tailwind"



cd "$PROJECT/frontend"



if [ ! -f package.json ]
then

npm init -y

fi



npm install \
tailwindcss \
@tailwindcss/cli \
postcss \
autoprefixer



echo "[10] Environment report"



cat > "$PROJECT/docs/environment.md" <<REPORT
# Config Manager Environment


Generated:

$(date)


## OS

$(cat /etc/os-release)


## Python

$(python3 --version)


## Node

$(node -v)


## NPM

$(npm -v)


## Nginx

$(nginx -v 2>&1)


## Git

$(git --version)


## Backend Packages

$(cat "$PROJECT/backend-requirements-lock.txt")

REPORT



echo "[11] Structure report"



tree "$PROJECT" \
> "$PROJECT/docs/structure-tree.txt" \
|| find "$PROJECT" > "$PROJECT/docs/structure-tree.txt"



echo "[12] Phase report"



cat > "$PROJECT/docs/PHASE-0.5-REPORT.md" <<REPORT
# Phase 0.5 Report


Status:

COMPLETED


Time:

$(date)


Environment prepared successfully.

REPORT



echo

echo "======================================"
echo " PHASE 0.5 COMPLETE"
echo "======================================"

