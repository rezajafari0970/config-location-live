#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="/var/lib/config-location/devlog-github/repo"
AGENT="/usr/local/bin/config-location-agent"

echo "=============================================="
echo " Config Location DevLog Sync Installer"
echo "=============================================="

if [ ! -d "$REPO/.git" ]; then
    echo "[ERROR] Git repository not found:"
    echo "$REPO"
    exit 1
fi

mkdir -p "$REPO/audit/history"


cat >/usr/local/bin/config-location-devlog-sync <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="/var/lib/config-location/devlog-github/repo"
SRC="/var/log/config-location-agent"

echo "=============================================="
echo " CONFIG LOCATION DEVLOG SYNC"
echo "=============================================="

cd "$REPO"


echo "[1/7] Pull latest GitHub..."

git pull --rebase origin main


echo "[2/7] Running Agent v2..."

config-location-agent


echo "[3/7] Copying reports..."

mkdir -p audit/history

cp "$SRC/latest.json" audit/latest.json
cp "$SRC/latest.txt"  audit/latest.txt


cp "$SRC"/history/*.json audit/history/ 2>/dev/null || true


echo "[4/7] Sanitizing..."

find audit -type f -exec sed -i \
-e 's/[0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}/[IP_REMOVED]/g' \
-e 's/vless:\/\/[^ ]*/[CONFIG_REMOVED]/g' \
-e 's/vmess:\/\/[^ ]*/[CONFIG_REMOVED]/g' \
-e 's/trojan:\/\/[^ ]*/[CONFIG_REMOVED]/g' \
-e 's/ss:\/\/[^ ]*/[CONFIG_REMOVED]/g' \
-e 's/[A-Za-z0-9_-]\{40,\}/[SECRET_REMOVED]/g' \
{} \;


echo "[5/7] Updating logs..."

cp "$SRC/latest.txt" latest.log
cp "$SRC/latest.txt" current.log


echo "[6/7] Git commit..."

git add \
latest.log \
current.log \
audit/


if git diff --cached --quiet; then
    echo "[OK] No changes"
    exit 0
fi


git commit \
-m "Config Location Agent v2 audit $(date -Is)"


echo "[7/7] Push GitHub..."

git push origin main


echo
echo "=============================================="
echo " DEVLOG SYNC SUCCESS"
echo "=============================================="
SCRIPT


chmod 700 /usr/local/bin/config-location-devlog-sync


echo
echo "Testing first sync..."

config-location-devlog-sync


echo
echo "=============================================="
echo " INSTALL COMPLETE"
echo "=============================================="

echo
echo "Command:"
echo "config-location-devlog-sync"

