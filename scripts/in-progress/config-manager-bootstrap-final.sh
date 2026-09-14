#!/usr/bin/env bash

set -euo pipefail


PROJECT="/opt/config-manager"

BASE="/root/project-reports"

ART="$BASE/artifacts"



echo "======================================"
echo " CONFIG MANAGER FINAL BOOTSTRAP"
echo " PHASE 0.5 + 0.6"
echo " VERIFIED EXPORT"
echo " ARTIFACT GATE"
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
rsync \
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



echo "[7] Artifact structure"



mkdir -p \
"$ART/environment" \
"$ART/baseline" \
"$ART/exports/config-manager" \
"$ART/manifests" \
"$ART/verification" \
"$ART/hashes"



echo "[8] Environment Manifest"



{

echo "# Environment Manifest"

echo

date

echo

echo "Python"

python3 --version


echo

echo "Node"

node -v


echo

echo "NPM"

npm -v


echo

echo "Nginx"

nginx -v 2>&1


} > "$ART/environment/environment-manifest.md"



echo "[9] Baseline"



find "$PROJECT" \
-type f \
-not -path "*/venv/*" \
-not -path "*/node_modules/*" \
> "$ART/baseline/project-files.txt"



cat > "$ART/baseline/baseline-report.md" <<REPORT
# Baseline Snapshot


Phase:

0.6


Status:

READY


Project:

$PROJECT


Generated:

$(date)

REPORT



echo "[10] Verified Export"



rsync -a \
--exclude venv \
--exclude node_modules \
"$PROJECT/" \
"$ART/exports/config-manager/"



FILES=$(find "$ART/exports/config-manager" -type f | wc -l)



if [ "$FILES" -eq 0 ]
then

echo "EXPORT FAILED"

exit 1

fi



find "$ART/exports/config-manager" \
-type f \
> "$ART/manifests/project-export-manifest.txt"



echo "[11] SHA256"



cd "$ART"


find exports \
-type f \
-exec sha256sum {} \; \
> hashes/config-manager.sha256



echo "[12] Verification"



cat > "$ART/verification/bootstrap-verification.md" <<VERIFY
# Bootstrap Verification


Status:

SUCCESS


Phases:

0.5

0.6


Export:

SUCCESS


Files:

$FILES


Generated:

$(date)

VERIFY



echo

echo "======================================"
echo " BOOTSTRAP READY FOR PIPELINE V2.6"
echo "======================================"

