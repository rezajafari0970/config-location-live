#!/usr/bin/env bash

set -euo pipefail


PROJECT="/opt/config-manager"


echo "======================================"
echo " CONFIG MANAGER PHASE 0.5"
echo " ENVIRONMENT PREPARATION V2"
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



echo "[3] Python"



apt install -y \
python3 \
python3-pip \
python3-venv \
python3-dev



python3 --version

pip3 --version



echo "[4] Node"



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



mkdir -p "$PROJECT"/{
backend,
frontend,
storage,
workers,
tests,
docs,
installer
}



echo "[7] Python venv"



if [ ! -d "$PROJECT/venv" ]
then

python3 -m venv "$PROJECT/venv"

fi



source "$PROJECT/venv/bin/activate"



pip install --upgrade pip



echo "[8] Backend dependencies"



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



pip freeze \
> "$PROJECT/backend-requirements-lock.txt"



deactivate



echo "[9] Frontend"



mkdir -p "$PROJECT/frontend"



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



echo "[10] Documentation"



mkdir -p "$PROJECT/docs/environment"



cat > "$PROJECT/docs/environment/environment.md" <<DOC
# Config Manager Environment


Generated:

$(date)


Python:

$(python3 --version)


Node:

$(node -v)


NPM:

$(npm -v)


Nginx:

$(nginx -v 2>&1)


Git:

$(git --version)

DOC



tree "$PROJECT" \
> "$PROJECT/docs/environment/structure-tree.txt" \
|| find "$PROJECT" > "$PROJECT/docs/environment/structure-tree.txt"



cat > "$PROJECT/docs/environment/phase-0.5-report.md" <<DOC
# Phase 0.5 Report


Status:

COMPLETED


Environment:

READY


Generated:

$(date)

DOC



echo

echo "======================================"
echo " PHASE 0.5 COMPLETE"
echo "======================================"

