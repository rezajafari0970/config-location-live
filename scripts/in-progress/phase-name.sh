#!/usr/bin/env bash

set -euo pipefail


# ==========================
# MAIN WORK
# ==========================

echo "[1] ..."
echo "[2] ..."
echo "[3] ..."



# ==========================
# INTERNAL REPORT
# ==========================

generate_report



# ==========================
# GITHUB SYNC
# ==========================

git add .
git commit -m "phase completed"
git push


