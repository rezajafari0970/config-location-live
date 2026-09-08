#!/usr/bin/env bash

set -euo pipefail

PROJECT="/opt/config-manager"

echo "======================================"
echo " CONFIG MANAGER AUTO PHASE 0 "
echo "======================================"

if [ "$(id -u)" != "0" ]; then
    echo "Run as root"
    exit 1
fi


echo "[1] Detecting OS"

source /etc/os-release

echo "OS: $PRETTY_NAME"


echo "[2] Updating system"

apt update -y
apt upgrade -y


echo "[3] Installing base tools"

apt install -y \
curl \
wget \
git \
nano \
vim \
htop \
tree \
unzip \
zip \
ca-certificates \
software-properties-common \
build-essential


echo "[4] Detecting Python"


PYTHON_BIN=""

for p in python3.12 python3.11 python3.10 python3; do
    if command -v "$p" >/dev/null 2>&1; then
        PYTHON_BIN=$(command -v "$p")
        break
    fi
done


if [ -z "$PYTHON_BIN" ]; then

    echo "Python not found. Installing..."

    apt install -y python3 python3-venv python3-pip

    PYTHON_BIN=$(command -v python3)

fi


echo "Python selected:"
$PYTHON_BIN --version


echo "[5] Installing Python tools"

apt install -y \
python3-venv \
python3-pip


echo "[6] Detecting Node.js"


if ! command -v node >/dev/null 2>&1; then

    echo "Installing Node.js"

    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -

    apt install -y nodejs

else

    echo "Node already installed"

fi


echo "Node:"
node -v


echo "[7] Installing Nginx"


if ! command -v nginx >/dev/null 2>&1; then

    apt install -y nginx

fi


systemctl enable nginx
systemctl restart nginx


echo "[8] Creating project"


mkdir -p "$PROJECT"


mkdir -p "$PROJECT"/{
backend,
frontend,
workers,
storage,
logs,
docs,
installer
}


mkdir -p "$PROJECT/storage"/{
sources,
configs,
errors,
cache,
backup
}



echo "[9] Creating Python environment"


cd "$PROJECT"


if [ ! -d venv ]; then

    "$PYTHON_BIN" -m venv venv

fi


source venv/bin/activate


echo "[10] Installing Python packages"


pip install --upgrade pip


pip install \
fastapi \
uvicorn \
pydantic \
python-multipart \
jinja2 \
aiofiles \
httpx \
pytest


deactivate



echo "[11] Creating documentation"


cat > "$PROJECT/docs/PROJECT_SPEC.md" <<EOF
# Config Manager

Backend:
Python + FastAPI

Frontend:
HTML CSS JavaScript TailwindCSS

Storage:
File Based

Database:
None

Architecture:
Modular
Automatic
Independent Workers

Phase:
0 Completed
