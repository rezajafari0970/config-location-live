#!/usr/bin/env bash

set -euo pipefail


PROJECT="/opt/config-manager"

BASE="/root/project-reports"

ART="$BASE/artifacts"



echo "======================================"
echo " CONFIG MANAGER BOOTSTRAP"
echo " PHASE 0.5 + 0.6"
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



echo "[4] Python environment"



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



echo "[6] Services"



systemctl enable nginx

systemctl restart nginx



echo "[7] Artifact folders"



mkdir -p \
"$ART/environment" \
"$ART/baseline" \
"$ART/manifests" \
"$ART/verification" \
"$ART/hashes"



echo "[8] Environment Export"



{

echo "# Environment Manifest"

echo

date

echo

python3 --version

node -v

npm -v

nginx -v 2>&1

} > "$ART/environment/environment-manifest.md"



echo "[9] Baseline Snapshot"



find "$PROJECT" \
-type f \
-not -path "*/venv/*" \
-not -path "*/node_modules/*" \
> "$ART/baseline/project-files.txt"



cat > "$ART/baseline/baseline-report.md" <<REPORT
# Config Manager Baseline


Phase:

0.6


Status:

READY


Project:

$PROJECT


Generated:

$(date)

REPORT



echo "[10] SHA256"



cd "$ART"


find . \
-type f \
-exec sha256sum {} \; \
> hashes/bootstrap.sha256



echo "[11] Verification"



cat > "$ART/verification/bootstrap-verification.md" <<REPORT
# Bootstrap Verification


Status:

SUCCESS


Phase:

0.5 + 0.6


Generated:

$(date)

REPORT



echo

echo "======================================"
echo " BOOTSTRAP COMPLETE"
echo "======================================"

