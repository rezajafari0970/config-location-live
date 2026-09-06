#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# CONFIG LOCATION - FINAL ROOT-ONLY FRESH INSTALLER
###############################################################################

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$SELF_DIR/payload"
META="$SELF_DIR/meta"

PROJECT="/opt/config-location"
VENV="$PROJECT/venv"

DATA="/var/lib/config-location"
CFG="/etc/config-location"
LOGDIR="/var/log/config-location"
RUN="/run/config-location"

PANEL="config-location-panel.service"
FETCHER="config-location-fetcher.service"

BACKUPS="/var/backups/config-location"

LOG="/root/config-location-final-install.log"

exec > >(tee -a "$LOG") 2>&1

echo
echo "================================================================"
echo " CONFIG LOCATION - FINAL ONE CLICK INSTALL"
echo "================================================================"
echo "Started: $(date)"
echo

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Run as root."
    exit 1
fi

###############################################################################
# SYSTEM
###############################################################################

echo "===== SYSTEM ====="

cat /etc/os-release || true
uname -a

###############################################################################
# DEPENDENCIES
###############################################################################

echo
echo "===== SYSTEM DEPENDENCIES ====="

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    wget \
    git \
    jq \
    unzip \
    zip \
    tar \
    gzip \
    xz-utils \
    rsync \
    openssl \
    gnupg \
    lsof \
    procps \
    psmisc \
    net-tools \
    iproute2 \
    iputils-ping \
    dnsutils \
    socat \
    sqlite3 \
    cron \
    logrotate \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    build-essential \
    pkg-config \
    gcc \
    g++ \
    make \
    cargo \
    rustc \
    libssl-dev \
    libffi-dev

dpkg --configure -a || true
apt-get -f install -y

echo "[PASS] System dependencies"

###############################################################################
# SERVICE USER
###############################################################################

echo
echo "===== SERVICE USER ====="

getent group configloc >/dev/null 2>&1 || \
    groupadd --system configloc

id configloc >/dev/null 2>&1 || \
    useradd \
        --system \
        --gid configloc \
        --home "$PROJECT" \
        --shell /usr/sbin/nologin \
        configloc

###############################################################################
# STOP ONLY CONFIG LOCATION
###############################################################################

echo
echo "===== STOP CONFIG LOCATION SERVICES ====="

systemctl stop "$PANEL" 2>/dev/null || true
systemctl stop "$FETCHER" 2>/dev/null || true

systemctl reset-failed "$PANEL" 2>/dev/null || true
systemctl reset-failed "$FETCHER" 2>/dev/null || true

###############################################################################
# ROLLBACK BACKUP
###############################################################################

echo
echo "===== ROLLBACK BACKUP ====="

mkdir -p "$BACKUPS"

STAMP="$(date +%Y%m%d-%H%M%S)"

if [ -d "$PROJECT" ] &&
   [ "$(find "$PROJECT" -mindepth 1 -print -quit 2>/dev/null)" ]; then

    tar -czf \
        "$BACKUPS/project-before-$STAMP.tar.gz" \
        "$PROJECT" \
        2>/dev/null || true

fi

if [ -d "$DATA" ] &&
   [ "$(find "$DATA" -mindepth 1 -print -quit 2>/dev/null)" ]; then

    tar -czf \
        "$BACKUPS/data-before-$STAMP.tar.gz" \
        "$DATA" \
        2>/dev/null || true

fi

###############################################################################
# RESTORE PROJECT
###############################################################################

echo
echo "===== RESTORE PROJECT ====="

mkdir -p "$PROJECT"

rsync -aH \
    --delete \
    "$PAYLOAD/opt/config-location/" \
    "$PROJECT/"

###############################################################################
# RESTORE DATA
###############################################################################

echo
echo "===== RESTORE DATA ====="

mkdir -p "$DATA"

if [ -d "$PAYLOAD/var/lib/config-location" ]; then

    rsync -aH \
        "$PAYLOAD/var/lib/config-location/" \
        "$DATA/"

fi

###############################################################################
# RESTORE CONFIG
###############################################################################

echo
echo "===== RESTORE CONFIG ====="

mkdir -p "$CFG"

if [ -d "$PAYLOAD/etc/config-location" ]; then

    rsync -aH \
        "$PAYLOAD/etc/config-location/" \
        "$CFG/"

fi

mkdir -p "$LOGDIR"

###############################################################################
# XRAY
###############################################################################

echo
echo "===== XRAY ====="

if [ -f "$PAYLOAD/usr/local/bin/xray" ]; then

    install \
        -o root \
        -g root \
        -m 0755 \
        "$PAYLOAD/usr/local/bin/xray" \
        /usr/local/bin/xray

    /usr/local/bin/xray version || true

fi

if [ -d "$PAYLOAD/usr/local/share/xray" ]; then

    mkdir -p /usr/local/share/xray

    rsync -aH \
        "$PAYLOAD/usr/local/share/xray/" \
        /usr/local/share/xray/

fi

###############################################################################
# SYSTEMD BASE UNITS
###############################################################################

echo
echo "===== SYSTEMD BASE UNITS ====="

for UNIT in "$PANEL" "$FETCHER"; do

    SRC="$PAYLOAD/etc/systemd/system/$UNIT"

    if [ ! -f "$SRC" ]; then
        echo "[ERROR] Missing $UNIT in snapshot"
        exit 1
    fi

    install \
        -o root \
        -g root \
        -m 0644 \
        "$SRC" \
        "/etc/systemd/system/$UNIT"

done

###############################################################################
# CLEAN ALL OLD OVERRIDES
###############################################################################

echo
echo "===== CLEAN OLD SYSTEMD OVERRIDES ====="

rm -rf \
    "/etc/systemd/system/$PANEL.d" \
    "/etc/systemd/system/$FETCHER.d"

mkdir -p \
    "/etc/systemd/system/$PANEL.d" \
    "/etc/systemd/system/$FETCHER.d"

###############################################################################
# FRESH VENV
###############################################################################

echo
echo "===== CREATE FRESH VENV ====="

rm -rf "$VENV"

/usr/bin/python3 -m venv "$VENV"

"$VENV/bin/python" \
    -m pip install \
    --upgrade \
    pip setuptools wheel

###############################################################################
# INSTALL EXACT SNAPSHOT DEPENDENCIES
###############################################################################

echo
echo "===== INSTALL SNAPSHOT PYTHON DEPENDENCIES ====="

LOCK="$META/requirements.snapshot.txt"

if [ ! -s "$LOCK" ]; then
    echo "[ERROR] Missing requirements.snapshot.txt"
    exit 1
fi

"$VENV/bin/python" \
    -m pip install \
    -r "$LOCK"

"$VENV/bin/python" \
    -m pip check

###############################################################################
# VENV PERMISSION FIX
###############################################################################

echo
echo "===== VENV PERMISSIONS ====="

chmod 755 /opt
chmod 755 "$PROJECT"

find "$PROJECT" \
    -type d \
    -exec chmod u+rwx,go+rx {} \;

find "$VENV" \
    -type d \
    -exec chmod 755 {} \;

find "$VENV/bin" \
    -maxdepth 1 \
    -type f \
    -exec chmod 755 {} \; \
    2>/dev/null || true

chmod 755 \
    "$VENV/bin/python" \
    2>/dev/null || true

chmod 755 \
    "$VENV/bin/python3" \
    2>/dev/null || true

PYREAL="$(
    readlink -f \
        "$VENV/bin/python" \
        2>/dev/null || true
)"

if [ -n "$PYREAL" ] && [ -e "$PYREAL" ]; then
    chmod 755 "$PYREAL" || true
fi

###############################################################################
# OWNERSHIP
###############################################################################

echo
echo "===== OWNERSHIP ====="

chown -R configloc:configloc "$PROJECT"
chown -R configloc:configloc "$DATA"
chown -R configloc:configloc "$CFG"
chown -R configloc:configloc "$LOGDIR"

###############################################################################
# RUNTIME
###############################################################################

echo
echo "===== RUNTIME DIRECTORY ====="

cat >/etc/tmpfiles.d/config-location.conf <<'TMP'
d /run/config-location 0750 configloc configloc -
TMP

systemd-tmpfiles \
    --create \
    /etc/tmpfiles.d/config-location.conf

install \
    -d \
    -o configloc \
    -g configloc \
    -m 0750 \
    "$RUN"

###############################################################################
# HARD IMPORT TEST
###############################################################################

echo
echo "===== ROOT IMPORT TEST ====="

cd "$PROJECT"

"$VENV/bin/python" - <<'PY'
import app
import httpx
import filelock

print("[PASS] app")
print("[PASS] httpx", httpx.__version__)
print("[PASS] filelock")
PY

echo
echo "===== CONFIGLOC IMPORT TEST ====="

cd "$PROJECT"

runuser -u configloc -- \
    "$VENV/bin/python" - <<'PY'
import app
import httpx
import filelock

print("[PASS] configloc app/httpx/filelock")
PY

###############################################################################
# CHECK VENV EXECUTION AS SERVICE USER
###############################################################################

echo
echo "===== CONFIGLOC EXEC TEST ====="

namei -l "$VENV/bin/python"

runuser -u configloc -- \
    test -x "$VENV/bin/python"

runuser -u configloc -- \
    "$VENV/bin/python" \
    --version

echo "[PASS] configloc can execute venv Python"

###############################################################################
# FINAL PANEL OVERRIDE
###############################################################################

echo
echo "===== PANEL OVERRIDE ====="

cat >"/etc/systemd/system/$PANEL.d/99-final.conf" <<EOF
[Service]
ExecStart=
ExecStart=$VENV/bin/python -m app.panel.server
WorkingDirectory=$PROJECT

RuntimeDirectory=config-location
RuntimeDirectoryMode=0750
RuntimeDirectoryPreserve=yes
EOF

###############################################################################
# FINAL FETCHER OVERRIDE
###############################################################################

echo
echo "===== FETCHER OVERRIDE ====="

BASE_FETCH="$(
    sed -n \
        's/^ExecStart=//p' \
        "/etc/systemd/system/$FETCHER" \
        | head -1
)"

if [ -z "$BASE_FETCH" ]; then
    echo "[ERROR] Fetcher base ExecStart missing"
    exit 1
fi

FETCH_ARGS="$(
    printf '%s\n' "$BASE_FETCH" |
    sed \
        -e "s#^${PROJECT}/venv/bin/python[[:space:]]*##" \
        -e "s#^${PROJECT}/.venv/bin/python[[:space:]]*##" \
        -e 's#^/usr/bin/python3[[:space:]]*##'
)"

if [ -z "$FETCH_ARGS" ]; then
    echo "[ERROR] Could not determine Fetcher module/arguments"
    exit 1
fi

echo "Fetcher arguments:"
echo "$FETCH_ARGS"

cat >"/etc/systemd/system/$FETCHER.d/99-final.conf" <<EOF
[Service]
ExecStart=
ExecStart=$VENV/bin/python $FETCH_ARGS
WorkingDirectory=$PROJECT

RuntimeDirectory=config-location
RuntimeDirectoryMode=0750
RuntimeDirectoryPreserve=yes
EOF

###############################################################################
# SYSTEMD RELOAD
###############################################################################

echo
echo "===== SYSTEMD RELOAD ====="

systemctl daemon-reload
systemd-tmpfiles --create

install \
    -d \
    -o configloc \
    -g configloc \
    -m 0750 \
    "$RUN"

###############################################################################
# EFFECTIVE VALIDATION
###############################################################################

echo
echo "===== EFFECTIVE EXECSTART ====="

PANEL_EXEC="$(
    systemctl show \
        "$PANEL" \
        -p ExecStart \
        --value
)"

FETCH_EXEC="$(
    systemctl show \
        "$FETCHER" \
        -p ExecStart \
        --value
)"

echo "Panel:"
echo "$PANEL_EXEC"

echo
echo "Fetcher:"
echo "$FETCH_EXEC"

echo "$PANEL_EXEC" |
    grep -q "$VENV/bin/python" || {
        echo "[ERROR] Panel does not use project venv"
        exit 1
    }

echo "$FETCH_EXEC" |
    grep -q "$VENV/bin/python" || {
        echo "[ERROR] Fetcher does not use project venv"
        exit 1
    }

###############################################################################
# ENABLE
###############################################################################

echo
echo "===== ENABLE SERVICES ====="

systemctl enable "$FETCHER"
systemctl enable "$PANEL"

###############################################################################
# START FETCHER
###############################################################################

START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

echo
echo "===== START FETCHER ====="

systemctl reset-failed "$FETCHER" || true
systemctl restart "$FETCHER"

sleep 6

if ! systemctl is-active --quiet "$FETCHER"; then

    echo "[ERROR] FETCHER FAILED"

    systemctl status \
        "$FETCHER" \
        --no-pager -l || true

    journalctl \
        -u "$FETCHER" \
        --since "$START_TIME" \
        --no-pager || true

    exit 1

fi

echo "[PASS] FETCHER ACTIVE"

###############################################################################
# START PANEL
###############################################################################

echo
echo "===== START PANEL ====="

systemctl reset-failed "$PANEL" || true
systemctl restart "$PANEL"

sleep 6

if ! systemctl is-active --quiet "$PANEL"; then

    echo "[ERROR] PANEL FAILED"

    systemctl status \
        "$PANEL" \
        --no-pager -l || true

    journalctl \
        -u "$PANEL" \
        --since "$START_TIME" \
        --no-pager || true

    exit 1

fi

echo "[PASS] PANEL ACTIVE"

###############################################################################
# PORT 4040
###############################################################################

echo
echo "===== PORT 4040 ====="

PORT_OK=0

for i in {1..15}; do

    if ss -lnt |
        grep -qE '[:.]4040[[:space:]]'; then

        PORT_OK=1
        break

    fi

    sleep 2

done

if [ "$PORT_OK" -ne 1 ]; then
    echo "[ERROR] Port 4040 is not listening"
    exit 1
fi

ss -lntp | grep ':4040'

echo "[PASS] PORT 4040"

###############################################################################
# HTTP
###############################################################################

echo
echo "===== HTTP TEST ====="

HTTP=""

for i in {1..10}; do

    HTTP="$(
        curl \
            -sS \
            -o /dev/null \
            -w '%{http_code}' \
            --max-time 5 \
            http://127.0.0.1:4040/ \
            2>/dev/null || true
    )"

    case "$HTTP" in
        200|301|302|303|307|308)
            break
            ;;
    esac

    sleep 2

done

case "$HTTP" in

    200|301|302|303|307|308)
        echo "[PASS] HTTP=$HTTP"
        ;;

    *)
        echo "[ERROR] HTTP=$HTTP"
        exit 1
        ;;

esac

###############################################################################
# NEW ERRORS ONLY
###############################################################################

echo
echo "===== NEW SERVICE ERRORS ====="

journalctl \
    -u "$PANEL" \
    -u "$FETCHER" \
    --since "$START_TIME" \
    -p err \
    --no-pager || true

###############################################################################
# SAVE INSTALLER COPY IN PROJECT
###############################################################################

cp -f \
    "$SELF_DIR/install.sh" \
    "$PROJECT/install-oneclick.sh"

chmod 700 \
    "$PROJECT/install-oneclick.sh"

###############################################################################
# FINAL
###############################################################################

echo
echo "================================================================"
echo "[SUCCESS] CONFIG LOCATION FINAL INSTALL COMPLETE"
echo "================================================================"

echo
echo "Panel   : $(systemctl is-active "$PANEL")"
echo "Fetcher : $(systemctl is-active "$FETCHER")"
echo "Port    : 4040"
echo "HTTP    : $HTTP"

echo
echo "Python:"
"$VENV/bin/python" --version

echo
echo "Log:"
echo "$LOG"

echo
echo "================================================================"
