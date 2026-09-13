#!/usr/bin/env bash
set -e

echo "======================================"
echo " Google Drive / rclone authentication"
echo "======================================"

command -v rclone >/dev/null || {
    echo "rclone not installed"
    exit 1
}

if ! rclone listremotes | grep -qx 'gdrive:'; then
    echo "ERROR: gdrive remote does not exist."
    exit 1
fi

echo
echo "[OK] gdrive remote found"
echo
echo "Starting headless Google authentication..."
echo
echo "IMPORTANT:"
echo "When asked:"
echo "Use web browser to automatically authenticate?"
echo "answer: n"
echo

rclone config reconnect gdrive:

echo
echo "======================================"
echo "Testing Google Drive..."
echo "======================================"

rclone lsd gdrive: --max-depth 1

echo
echo "[SUCCESS] Google Drive connected."
