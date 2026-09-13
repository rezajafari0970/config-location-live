#!/usr/bin/env bash
set -Eeuo pipefail

REPO="/var/lib/config-location/devlog-github/repo"

cd "$REPO"

echo "================================"
echo " RESTORE GIT REMOTE"
echo "================================"


git remote -v || true


git remote add origin \
git@github.com:rezajafari0970/Devlog_fetch-x-ray-country.git \
2>/dev/null || \
git remote set-url origin \
git@github.com:rezajafari0970/Devlog_fetch-x-ray-country.git


echo
echo "Remote:"
git remote -v


echo
echo "Pushing cleaned history..."

git push origin main --force


echo
echo "Status:"
git status


echo "================================"
echo " REMOTE RESTORE COMPLETE"
echo "================================"

