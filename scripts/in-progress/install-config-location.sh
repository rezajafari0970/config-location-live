#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# CONFIG LOCATION - PORTABLE ROOT-ONLY LAUNCHER
###############################################################################

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="/root/.config-location-final-install"

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Run as root."
    exit 1
fi

echo
echo "============================================================"
echo " CONFIG LOCATION - ROOT-ONLY INSTALL LAUNCHER"
echo "============================================================"
echo

ARCHIVE="$(
    find "$DIR" \
        -maxdepth 1 \
        -type f \
        -name 'config-location-final-*.tar.gz' \
        -printf '%T@ %p\n' |
    sort -nr |
    head -1 |
    cut -d' ' -f2-
)"

if [ -z "${ARCHIVE:-}" ] ||
   [ ! -f "$ARCHIVE" ]; then

    echo "[ERROR] No final Config Location archive found beside installer."
    exit 1

fi

SHA="${ARCHIVE}.sha256"

echo "Archive:"
echo "$ARCHIVE"
echo

if [ ! -f "$SHA" ]; then

    echo "[ERROR] Missing SHA256:"
    echo "$SHA"
    exit 1

fi

EXPECTED="$(
    awk '{print $1}' "$SHA" |
    head -1
)"

ACTUAL="$(
    sha256sum "$ARCHIVE" |
    awk '{print $1}'
)"

echo "Expected SHA256:"
echo "$EXPECTED"

echo
echo "Actual SHA256:"
echo "$ACTUAL"

if [ "$EXPECTED" != "$ACTUAL" ]; then

    echo
    echo "[ERROR] SHA256 mismatch."
    exit 1

fi

echo
echo "[PASS] SHA256"

rm -rf "$WORK"

mkdir -p "$WORK"

echo
echo "===== EXTRACT ====="

tar \
    -xzf "$ARCHIVE" \
    -C "$WORK"

INSTALLER="$(
    find "$WORK" \
        -mindepth 2 \
        -maxdepth 2 \
        -type f \
        -name install.sh \
        | head -1
)"

if [ -z "${INSTALLER:-}" ] ||
   [ ! -f "$INSTALLER" ]; then

    echo "[ERROR] install.sh not found inside archive."
    exit 1

fi

echo "[PASS] Installer:"
echo "$INSTALLER"

chmod +x "$INSTALLER"

echo
echo "===== START INSTALL ====="
echo

bash "$INSTALLER"
