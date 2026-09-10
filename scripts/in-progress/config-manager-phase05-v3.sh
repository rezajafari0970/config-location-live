#!/usr/bin/env bash

set -euo pipefail


PROJECT="/opt/config-manager"


echo "======================================"
echo " CONFIG MANAGER PHASE 0.5 V3"
echo " ENVIRONMENT PREPARATION"
echo "======================================"



echo "[1] System packages"


apt update -y


apt install -y \
curl \
wget \
git \
tree \
unzip \
zip \
build-essential \
software-properties-common \
pkg-config \
nginx \
python3 \
python3-pip \
python3-venv \
python3-dev



echo "[2] Node"



if ! command -v node >/dev/null 2>&1
then

curl -fsSL https://deb.nodesource.com/setup_22.x | bash -

apt install -y nodejs

fi



echo "[3] Project structure"



mkdir -p \
"$PROJECT/backend" \
"$PROJECT/frontend" \
"$PROJECT/storage" \
"$PROJECT/workers" \
"$PROJECT/tests" \
"$PROJECT/docs" \
"$PROJECT/installer"



echo "[4] Python venv"



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
pydantic \
python-multipart \
pytest \
pytest-asyncio \
ruff \
black



pip freeze \
> "$PROJECT/docs/packages.txt"



deactivate



echo "[5] Frontend"



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



echo "[6] Nginx"



systemctl enable nginx

systemctl restart nginx



echo "[7] Environment reports"



mkdir -p "$PROJECT/docs/environment"



python3 --version \
> "$PROJECT/docs/environment/python.md"


node -v \
> "$PROJECT/docs/environment/node.md"


npm -v \
> "$PROJECT/docs/environment/npm.md"


nginx -v \
> "$PROJECT/docs/environment/nginx.md" 2>&1



cat /etc/os-release \
> "$PROJECT/docs/environment/os.md"



tree "$PROJECT" \
> "$PROJECT/docs/environment/structure.md" \
|| find "$PROJECT" > "$PROJECT/docs/environment/structure.md"



cat > "$PROJECT/docs/PHASE-0.5-REPORT.md" <<REPORT
# Phase 0.5 Environment


Status:

READY


Generated:

$(date)

REPORT



echo

echo "======================================"
echo " PHASE 0.5 V3 COMPLETE"
echo "======================================"

