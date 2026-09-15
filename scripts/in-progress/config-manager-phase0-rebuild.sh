#!/usr/bin/env bash

set -euo pipefail


LOG="/root/config-manager-phase0-runtime.log"

exec > >(tee -a "$LOG")
exec 2>&1


echo "======================================"
echo " CONFIG MANAGER"
echo " PHASE 0 COMPLETE ENVIRONMENT REBUILD"
echo "======================================"

date


if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root"
    exit 1
fi



PROJECT="/opt/config-manager"

SERVICE_USER="configmanager"



echo "[1] System Update"


apt update -y
apt upgrade -y



echo "[2] Base Packages"


apt install -y \
curl \
wget \
git \
tree \
nano \
vim \
htop \
rsync \
zip \
unzip \
ca-certificates \
build-essential \
software-properties-common \
pkg-config \
nginx



echo "[3] Python Setup"


apt install -y \
python3 \
python3-pip \
python3-venv \
python3-dev



python3 --version
pip3 --version



echo "[4] Node Setup"



if ! command -v node >/dev/null 2>&1
then

curl -fsSL https://deb.nodesource.com/setup_22.x | bash -

apt install -y nodejs

fi



node -v
npm -v



echo "[5] Service User"



if ! id "$SERVICE_USER" >/dev/null 2>&1
then

useradd \
-r \
-m \
-d /opt/config-manager \
-s /usr/sbin/nologin \
"$SERVICE_USER"

fi



echo "[6] Project Structure"



mkdir -p \
"$PROJECT/backend/app/core" \
"$PROJECT/backend/app/api" \
"$PROJECT/backend/app/storage" \
"$PROJECT/backend/app/logger" \
"$PROJECT/frontend/templates" \
"$PROJECT/frontend/static" \
"$PROJECT/frontend/assets" \
"$PROJECT/storage/sources" \
"$PROJECT/storage/configs" \
"$PROJECT/storage/health" \
"$PROJECT/storage/logs" \
"$PROJECT/storage/reports" \
"$PROJECT/storage/backup" \
"$PROJECT/workers" \
"$PROJECT/tests" \
"$PROJECT/docs" \
"$PROJECT/installer"



echo "[7] Permission"



chown -R \
"$SERVICE_USER:$SERVICE_USER" \
"$PROJECT"



chmod -R 750 "$PROJECT"



echo "[8] Python Virtual Environment"



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
> "$PROJECT/docs/python-packages.txt"



deactivate



echo "[9] Frontend Setup"



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



echo "[10] Nginx"



systemctl enable nginx

systemctl restart nginx



echo "[11] Environment Reports"



REPORT="$PROJECT/docs/phase0-report"

mkdir -p "$REPORT"



cat /etc/os-release \
> "$REPORT/os.txt"



python3 --version \
> "$REPORT/python.txt"



node -v \
> "$REPORT/node.txt"



npm -v \
> "$REPORT/npm.txt"



nginx -v 2>&1 \
> "$REPORT/nginx.txt"



dpkg --get-selections \
> "$REPORT/packages.txt"



tree "$PROJECT" \
> "$REPORT/structure.txt" \
|| find "$PROJECT" > "$REPORT/structure.txt"



cat > "$PROJECT/docs/PHASE0-COMPLETE.md" <<DOC
# Config Manager Phase 0


Status:

COMPLETED


Project:

$PROJECT


Service User:

$SERVICE_USER


Generated:

$(date)

DOC



echo

echo "======================================"
echo " PHASE 0 COMPLETE"
echo "======================================"

echo "Runtime Log:"
echo "$LOG"

echo "Project:"
echo "$PROJECT"

