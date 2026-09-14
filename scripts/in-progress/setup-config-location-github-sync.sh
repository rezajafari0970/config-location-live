#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="https://github.com/rezajafari0970/Devlog_fetch_x-ray-country.git"
WORK="/root/config-location-devlog"

echo "=============================================="
echo " CONFIG LOCATION GITHUB DEVLOG SYNC SETUP"
echo "=============================================="

command -v git >/dev/null || {
    apt update -y
    apt install -y git
}

echo "[1/6] Preparing repository..."

if [ -d "$WORK/.git" ]; then
    cd "$WORK"
    git pull --rebase || true
else
    rm -rf "$WORK"
    git clone "$REPO" "$WORK"
    cd "$WORK"
fi


echo "[2/6] Creating audit structure..."

mkdir -p \
"$WORK/audit/history"


echo "[3/6] Installing sync command..."

cat >/usr/local/bin/config-location-devlog-sync <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SRC="/var/log/config-location-agent"
DST="/root/config-location-devlog"

echo "=============================================="
echo " CONFIG LOCATION DEVLOG SYNC"
echo "=============================================="


if [ ! -d "$DST/.git" ]; then
    echo "[ERROR] Git repo missing"
    exit 1
fi


echo "[1] Running audit..."

config-location-agent


echo "[2] Sanitizing reports..."

mkdir -p "$DST/audit/history"


cp "$SRC/latest.json" \
"$DST/audit/latest.json"

cp "$SRC/latest.txt" \
"$DST/audit/latest.txt"


cp "$SRC"/history/*.json \
"$DST/audit/history/" 2>/dev/null || true


echo "[3] Removing sensitive data..."

find "$DST/audit" -type f -exec sed -i \
-e 's/[A-Za-z0-9_-]\{30,\}/[REDACTED]/g' \
-e 's/[0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}/[IP-REDACTED]/g' \
{} \;


echo "[4] Git update..."

cd "$DST"

git add audit/


if git diff --cached --quiet; then
    echo "[OK] No changes"
    exit 0
fi


git commit \
-m "Config Location audit $(date -Is)"


echo "[5] Push..."

git push


echo
echo "=============================================="
echo " GITHUB SYNC SUCCESS"
echo "=============================================="
SCRIPT


chmod 700 /usr/local/bin/config-location-devlog-sync


echo "[4/6] First sync..."

config-location-devlog-sync


echo
echo "=============================================="
echo " SETUP COMPLETE"
echo "=============================================="

echo
echo "Command:"
echo "  config-location-devlog-sync"

