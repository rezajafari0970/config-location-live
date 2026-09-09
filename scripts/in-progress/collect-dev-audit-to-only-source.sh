#!/bin/bash
set -e

DEST="/root/only-source-code-final/development-audit"

mkdir -p "$DEST"

SRC="/opt/config-location"

echo "[1] Project tree"
tree -a -L 6 "$SRC" > "$DEST/project-tree.txt" 2>/dev/null || true

echo "[2] File list"
find "$SRC" -type f \
-not -path "*/venv/*" \
-not -path "*/backups/*" \
-not -path "*/__pycache__/*" \
-not -name "*.pyc" \
-not -name "*.log" \
> "$DEST/source-files.txt"

echo "[3] File sizes"
find "$SRC" -type f \
-not -path "*/venv/*" \
-not -path "*/backups/*" \
-printf "%s %p\n" \
| sort -nr > "$DEST/file-size-map.txt"

echo "[4] Classes and functions"
grep -R "^class \|^def " "$SRC/app" \
> "$DEST/code-map.txt" 2>/dev/null || true

echo "[5] Entry points"
grep -R \
"if __name__\|FastAPI\|Flask\|uvicorn\|def main" \
"$SRC" \
> "$DEST/entry-points.txt" 2>/dev/null || true

echo "[6] Dependencies"
find "$SRC" \
-name "requirements*" \
-o -name "pyproject.toml" \
-o -name "setup.py" \
> "$DEST/dependencies.txt"

echo "[7] Installer"
find "$SRC/installer" -type f \
> "$DEST/installer-files.txt" 2>/dev/null || true

echo "[8] Systemd services"
systemctl list-units --type=service \
| grep config-location \
> "$DEST/systemd-list.txt" || true

for s in $(systemctl list-units --type=service --no-legend \
| awk '/config-location/{print $1}')
do
    echo "===== $s =====" >> "$DEST/systemd-content.txt"
    systemctl cat "$s" >> "$DEST/systemd-content.txt" 2>&1
done

echo "[9] Runtime structure"
find /var/lib/config-location \
-maxdepth 3 -type d \
> "$DEST/runtime-tree.txt" 2>/dev/null || true

echo "[10] Runtime size"
du -sh /var/lib/config-location/* \
> "$DEST/runtime-size.txt" 2>/dev/null || true

echo "[11] Logs"
journalctl -u 'config-location*' \
-n 300 --no-pager \
> "$DEST/service-logs.txt" 2>/dev/null || true

echo "[12] System info"
{
echo "===== OS ====="
cat /etc/os-release

echo "===== Python ====="
python3 --version

echo "===== Disk ====="
df -h

echo "===== Memory ====="
free -h

echo "===== CPU ====="
lscpu | head -40

} > "$DEST/system-info.txt"


echo "[13] Compress audit folder"

tar -C /root/only-source-code-final \
-cf - development-audit \
| zstd -10 -T0 \
-o /root/only-source-code-final/development-audit.tar.zst


sha256sum \
/root/only-source-code-final/development-audit.tar.zst \
> /root/only-source-code-final/development-audit.tar.zst.sha256


echo
echo "DONE"
ls -lh /root/only-source-code-final

