#!/usr/bin/env bash

set -euo pipefail


PROJECT="/opt/config-manager"

BASE="/root/project-reports"

ART="/root/project-artifacts/baseline"


echo "======================================"
echo " CONFIG MANAGER PHASE 0.6"
echo " BASELINE SNAPSHOT COLLECTOR"
echo "======================================"



echo "[1] Create baseline structure"



mkdir -p \
"$ART/system" \
"$ART/config-manager" \
"$ART/manifests" \
"$ART/hashes"



echo "[2] System snapshot"



{

echo "# System Baseline"

echo

echo "Generated:"

date

echo

echo "OS"

cat /etc/os-release


echo

echo "Kernel"

uname -a


echo

echo "Memory"

free -h


echo

echo "Disk"

df -h


} > "$ART/system/system-baseline.md"



echo "[3] Environment snapshot"



{

echo "# Environment Manifest"

echo

echo "Python"

python3 --version


echo

echo "Pip"

pip3 --version


echo

echo "Node"

node -v 2>/dev/null || true


echo

echo "NPM"

npm -v 2>/dev/null || true


echo

echo "Nginx"

nginx -v 2>&1 || true


} > "$ART/manifests/environment-manifest.txt"



echo "[4] Project manifest"



if [ -d "$PROJECT" ]
then

find "$PROJECT" \
-type f \
-not -path "*/venv/*" \
-not -path "*/node_modules/*" \
> "$ART/manifests/project-manifest.txt"

else

echo "PROJECT_NOT_FOUND" \
> "$ART/manifests/project-manifest.txt"

fi



echo "[5] Copy important metadata"



mkdir -p "$BASE/artifacts/baseline"



cat > "$BASE/artifacts/baseline/baseline-report.md" <<REPORT
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



cp "$ART/manifests/project-manifest.txt" \
"$BASE/artifacts/baseline/"


cp "$ART/manifests/environment-manifest.txt" \
"$BASE/artifacts/baseline/"



echo "[6] SHA256"



cd "$ART"


find . \
-type f \
-exec sha256sum {} \; \
> hashes/baseline.sha256



cp hashes/baseline.sha256 \
"$BASE/artifacts/baseline/"



echo

echo "======================================"
echo " PHASE 0.6 BASELINE COMPLETE"
echo "======================================"

