#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="/root/project-reports"
TOKEN_FILE="/root/.github_token"

echo "======================================"
echo " GitHub Authentication Setup "
echo "======================================"


if [ "$(id -u)" != "0" ]; then
    echo "Run as root"
    exit 1
fi


echo
echo "[1] Checking SSH Deploy Key"


if [ -f /root/.ssh/config-manager-evidence ]; then
    echo "Deploy Key exists"

else
    echo "Deploy Key not found"
    exit 1
fi



echo
echo "[2] Testing SSH GitHub access"

ssh -T github-config-manager || true



echo
echo "[3] Git SSH Remote Setup"


cd "$REPO_DIR"

git remote remove origin 2>/dev/null || true

git remote add origin \
git@github-config-manager:rezajafari0970/config-manager-evidence.git


echo "Remote:"
git remote -v



echo
echo "[4] GitHub API Token Setup"

echo "Paste GitHub Token:"
read -s TOKEN


if [ -z "$TOKEN" ]; then
    echo "Token empty"
    exit 1
fi


echo "$TOKEN" > "$TOKEN_FILE"

chmod 600 "$TOKEN_FILE"


echo "Token saved:"
echo "$TOKEN_FILE"



echo
echo "[5] Creating API environment file"


cat > /root/.github_env <<EOF
export GITHUB_TOKEN_FILE=$TOKEN_FILE
export GITHUB_OWNER=rezajafari0970
export GITHUB_REPO=config-manager-evidence
