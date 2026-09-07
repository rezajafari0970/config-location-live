#!/bin/bash

set -Eeuo pipefail

ROOT="/root/only-source-code-final"

PROJECT="/opt/config-location"

OUT="$ROOT/development-audit"

rm -rf "$OUT"

mkdir -p "$OUT"


echo "===================================="
echo " FULL DEVELOPMENT INTELLIGENCE AUDIT"
echo "===================================="


####################################
# PROJECT STRUCTURE
####################################

echo "[1] Project tree"

tree -a -L 6 "$PROJECT" \
> "$OUT/project-tree.txt" 2>/dev/null || true



####################################
# FILE INVENTORY
####################################

echo "[2] File inventory"

find "$PROJECT" \
-type f \
-not -path "*/venv/*" \
-not -path "*/__pycache__/*" \
-printf "%s %p\n" \
| sort -nr \
> "$OUT/file-inventory.txt"



####################################
# CODE MAP
####################################

echo "[3] Code map"

grep -R "^class \|^def " \
"$PROJECT/app" \
> "$OUT/code-map.txt" 2>/dev/null || true



####################################
# IMPORT MAP
####################################

echo "[4] Import map"

grep -R "^import \|^from " \
"$PROJECT/app" \
> "$OUT/import-map.txt" 2>/dev/null || true



####################################
# API MAP
####################################

echo "[5] API map"

grep -R \
"@app\.|router\.|route|endpoint|FastAPI|Flask" \
"$PROJECT/app" \
> "$OUT/api-map.txt" 2>/dev/null || true



####################################
# ENTRY POINTS
####################################

echo "[6] Entry points"

grep -R \
"if __name__\|def main\|uvicorn\|argparse" \
"$PROJECT" \
> "$OUT/entry-points.txt" 2>/dev/null || true



####################################
# WORKERS
####################################

echo "[7] Workers"

find "$PROJECT" \
-type f \
| grep -Ei \
"worker|daemon|scheduler|consumer|runner" \
> "$OUT/workers.txt"



####################################
# SYSTEMD
####################################

echo "[8] Systemd"

systemctl list-units \
--type=service \
| grep -Ei \
"config|location|health|country|fetch" \
> "$OUT/systemd-list.txt" || true


for s in $(cat "$OUT/systemd-list.txt" | awk '{print $1}')
do
echo "========== $s ==========" >> "$OUT/systemd-content.txt"
systemctl cat "$s" >> "$OUT/systemd-content.txt" 2>&1 || true
done



####################################
# RUNTIME MAP
####################################

echo "[9] Runtime"

find /var/lib/config-location \
-maxdepth 3 \
-type d \
> "$OUT/runtime-tree.txt" 2>/dev/null || true


du -h --max-depth=2 \
/var/lib/config-location \
> "$OUT/runtime-size.txt" 2>/dev/null || true



####################################
# DEPENDENCY
####################################

echo "[10] Dependencies"

find "$PROJECT" \
-type f \
\( \
-name "requirements*" \
-o -name "pyproject.toml" \
-o -name "setup.py" \
\) \
> "$OUT/dependencies.txt"



####################################
# TEST MAP
####################################

echo "[11] Tests"

find "$PROJECT/tests" \
-type f \
> "$OUT/tests-map.txt" 2>/dev/null || true



####################################
# SECURITY
####################################

echo "[12] Security"

find "$PROJECT" \
-type f \
-perm /o+w \
> "$OUT/world-writable.txt" 2>/dev/null || true


find "$PROJECT" \
-type f \
\( \
-name "*.env" \
-o -name "*secret*" \
-o -name "*token*" \
-o -name "*key*" \
\) \
> "$OUT/sensitive-files-map.txt" 2>/dev/null || true



####################################
# GIT / BACKUP HISTORY
####################################

echo "[13] History"

find "$PROJECT" \
-type f \
\( \
-name "*.bak*" \
-o -name "*.before*" \
\) \
> "$OUT/history-files.txt"



####################################
# HASH
####################################

echo "[14] Manifest"

find "$PROJECT" \
-type f \
-not -path "*/venv/*" \
-print0 \
| sort -z \
| xargs -0 sha256sum \
> "$OUT/source-sha256.txt"



####################################
# SUMMARY
####################################

cat > "$OUT/SUMMARY.txt" <<TXT

CONFIG LOCATION DEVELOPMENT AUDIT

Project:
$PROJECT

Generated:
$(date)

Includes:

- Source map
- Classes/functions
- Imports
- APIs
- Workers
- Systemd
- Runtime structure
- Dependencies
- Tests
- Security map
- History files
- SHA256

TXT



####################################
# PACK REPORT
####################################

tar -cf - \
-C "$ROOT" \
development-audit \
| zstd -10 -T0 \
-o "$ROOT/development-audit.tar.zst"


sha256sum "$ROOT/development-audit.tar.zst" \
> "$ROOT/development-audit.tar.zst.sha256"


echo
echo "DONE"

ls -lh "$ROOT/development-audit.tar.zst"

