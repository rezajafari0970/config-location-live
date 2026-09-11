#!/usr/bin/env bash

set -euo pipefail

BASE="/root/project-reports"

echo "Creating GitHub Evidence Bridge..."


mkdir -p "$BASE"

mkdir -p "$BASE/reports/phase0"
mkdir -p "$BASE/reports/phase1"
mkdir -p "$BASE/reports/archive"

mkdir -p "$BASE/diagnostics"
mkdir -p "$BASE/snapshots"
mkdir -p "$BASE/scripts"


cat > "$BASE/README.md" <<'DOC'
# Project Evidence Repository

Stores:
- Reports
- Diagnostics
- Snapshots
- Development Evidence
DOC



cat > "$BASE/scripts/generate-report.sh" <<'SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

BASE="/root/project-reports"

DATE=$(date +%Y%m%d-%H%M%S)

OUT="$BASE/reports/report-$DATE"

mkdir -p "$OUT"


echo "Generating report..."


uname -a > "$OUT/system.txt"

cat /etc/os-release >> "$OUT/system.txt"


{
echo "===== MEMORY ====="
free -h

echo

echo "===== DISK ====="
df -h

echo

echo "===== CPU ====="
lscpu | head -30

} > "$OUT/resources.txt"



{
echo "===== Python ====="
python3 --version 2>&1 || true

echo

echo "===== Node ====="
node -v 2>&1 || true

echo

echo "===== Nginx ====="
nginx -v 2>&1 || true

echo

echo "===== Git ====="
git --version 2>&1 || true

} > "$OUT/versions.txt"



systemctl --type=service --state=running > "$OUT/services.txt"



ss -lntup > "$OUT/ports.txt"



if [ -d /opt ]; then
    tree -L 3 /opt > "$OUT/opt-tree.txt" 2>&1 || true
fi



journalctl -p err -n 100 > "$OUT/recent-errors.txt" 2>&1 || true


echo "REPORT CREATED:"
echo "$OUT"

SCRIPT


chmod +x "$BASE/scripts/generate-report.sh"



echo "GitHub Evidence Bridge installed"

echo
echo "Generate report:"
echo "$BASE/scripts/generate-report.sh"

