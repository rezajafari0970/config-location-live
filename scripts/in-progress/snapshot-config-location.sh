#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/opt/config-location"
OUTROOT="/root/spn/root"

TS="$(date -u +%Y%m%d-%H%M%S)"
NAME="config-location-full-snapshot-${TS}"
WORK="${OUTROOT}/${NAME}"
ARCHIVE="${OUTROOT}/${NAME}.tar.gz"
SHA="${ARCHIVE}.sha256"

mkdir -p "$OUTROOT"
mkdir -p "$WORK"

echo "============================================================"
echo " CONFIG LOCATION — FULL PROJECT SNAPSHOT"
echo " UTC=$TS"
echo " OUTPUT=$OUTROOT"
echo "============================================================"

echo
echo "===== 1. PRECHECK ====="

test -d "$PROJECT"

echo "PROJECT=$PROJECT"
echo "[PASS] project exists"

echo
echo "===== 2. PROJECT SOURCE ====="

mkdir -p "$WORK/project"

rsync -aHAX \
  --numeric-ids \
  --exclude='venv/' \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='.pytest_cache/' \
  --exclude='.mypy_cache/' \
  --exclude='.git/' \
  --exclude='tmp/' \
  --exclude='temp/' \
  --exclude='cache/' \
  "$PROJECT/" \
  "$WORK/project/"

echo "[PASS] project source copied"

echo
echo "===== 3. PROJECT METADATA ====="

mkdir -p "$WORK/meta"

{
    echo "UTC=$(date -u +%FT%TZ)"
    echo "HOST=$(hostname)"
    echo "KERNEL=$(uname -a)"
    echo
    echo "PROJECT=$PROJECT"
    echo
    echo "DISK:"
    df -h "$PROJECT" || true
    echo
    echo "PYTHON:"
    "$PROJECT/venv/bin/python" --version 2>&1 || true
    echo
    echo "XRAY:"
    xray version 2>&1 | head -n 20 || true
} > "$WORK/meta/system.txt"

echo "[PASS] metadata"

echo
echo "===== 4. PYTHON DEPENDENCIES ====="

if [ -x "$PROJECT/venv/bin/pip" ]; then
    "$PROJECT/venv/bin/pip" freeze \
      > "$WORK/meta/pip-freeze.txt" \
      2>/dev/null \
      || true
fi

echo "[PASS] dependency list"

echo
echo "===== 5. ETC CONFIG ====="

mkdir -p "$WORK/etc"

if [ -d /etc/config-location ]; then
    cp -a \
      /etc/config-location \
      "$WORK/etc/config-location"
fi

echo "[PASS] /etc/config-location"

echo
echo "===== 6. SYSTEMD UNITS ====="

mkdir -p "$WORK/systemd"

for UNIT in \
  config-location-panel.service \
  config-location-fetcher.service \
  config-location-health-adaptive.service \
  config-location-lifecycle-sync.service \
  config-location-lifecycle-watchdog.service
do
    systemctl cat "$UNIT" \
      > "$WORK/systemd/${UNIT}.txt" \
      2>&1 \
      || true
done

systemctl list-unit-files \
  | grep -E '^config-location-' \
  > "$WORK/systemd/unit-files.txt" \
  || true

echo "[PASS] systemd units"

echo
echo "===== 7. CURRENT SERVICE STATUS ====="

mkdir -p "$WORK/status"

for UNIT in \
  config-location-panel.service \
  config-location-fetcher.service \
  config-location-health-adaptive.service \
  config-location-lifecycle-sync.service \
  config-location-lifecycle-watchdog.service
do
    {
        echo "===== $UNIT ====="

        systemctl status \
          "$UNIT" \
          --no-pager \
          -l \
          || true

        echo

        systemctl show \
          "$UNIT" \
          -p User \
          -p Group \
          -p ExecStart \
          -p WorkingDirectory \
          -p MainPID \
          -p ActiveState \
          -p SubState \
          -p NRestarts \
          || true

    } > "$WORK/status/${UNIT}.txt"
done

echo "[PASS] service status"

echo
echo "===== 8. RUNTIME STATE ====="

mkdir -p "$WORK/state"

copy_dir() {

    SRC="$1"
    DST="$2"

    if [ -d "$SRC" ]; then

        mkdir -p "$DST"

        rsync -aH           --numeric-ids           --exclude='*.tmp'           --exclude='.*.tmp'           --exclude='*.partial'           --exclude='*.lock'           "$SRC/"           "$DST/"           || {
              RC=$?

              # rsync 24 = source files vanished while
              # live services were updating the store.
              if [ "$RC" -eq 24 ]; then
                  echo "[WARN] live files changed during snapshot; continuing"
              else
                  return "$RC"
              fi
          }
    fi
}

copy_dir \
  /var/lib/config-location/health-lifecycle \
  "$WORK/state/health-lifecycle"

copy_dir \
  /var/lib/config-location/health-adaptive \
  "$WORK/state/health-adaptive"

copy_dir \
  /var/lib/config-location/health-results \
  "$WORK/state/health-results"

copy_dir \
  /var/lib/config-location/configs \
  "$WORK/state/configs"

echo "[PASS] runtime state"

echo
echo "===== 9. IMPORTANT LOG SNAPSHOT ====="

mkdir -p "$WORK/logs"

for UNIT in \
  config-location-panel.service \
  config-location-fetcher.service \
  config-location-health-adaptive.service \
  config-location-lifecycle-sync.service \
  config-location-lifecycle-watchdog.service
do
    journalctl \
      -u "$UNIT" \
      --since "-24 hours" \
      --no-pager \
      > "$WORK/logs/${UNIT}.log" \
      2>&1 \
      || true
done

if [ -d /var/log/config-location/chatgpt ]; then

    mkdir -p "$WORK/logs/chatgpt"

    find /var/log/config-location/chatgpt \
      -maxdepth 2 \
      -type f \
      -mtime -7 \
      -print0 \
    | while IFS= read -r -d '' F
    do
        REL="${F#/var/log/config-location/chatgpt/}"

        mkdir -p \
          "$WORK/logs/chatgpt/$(dirname "$REL")"

        cp -a \
          "$F" \
          "$WORK/logs/chatgpt/$REL"
    done
fi

echo "[PASS] important logs"

echo
echo "===== 10. NETWORK / PORT MAP ====="

{
    echo "===== LISTEN ====="
    ss -lntp || true

    echo
    echo "===== CONFIG LOCATION FILTER ====="

    ss -lntp \
      | grep -E ':4040|config-location|python' \
      || true

} > "$WORK/meta/network.txt"

echo "[PASS] port map"

echo
echo "===== 11. FILE OWNERSHIP / PERMISSIONS ====="

{
    echo "===== PROJECT ROOT ====="
    stat "$PROJECT" || true

    echo
    echo "===== PROJECT TOP LEVEL ====="

    find "$PROJECT" \
      -maxdepth 2 \
      -printf '%M %u:%g %p\n' \
      | sort

    echo
    echo "===== ETC ====="

    find /etc/config-location \
      -maxdepth 2 \
      -printf '%M %u:%g %p\n' \
      2>/dev/null \
      | sort \
      || true

} > "$WORK/meta/permissions.txt"

echo "[PASS] ownership metadata"

echo
echo "===== 12. SNAPSHOT MANIFEST ====="

{
    echo "CONFIG LOCATION FULL SNAPSHOT"
    echo
    echo "UTC=$(date -u +%FT%TZ)"
    echo "PROJECT=$PROJECT"
    echo "OUTPUT=$OUTROOT"
    echo
    echo "INCLUDES:"
    echo "- project source"
    echo "- /etc/config-location"
    echo "- systemd unit definitions"
    echo "- health lifecycle state"
    echo "- health adaptive state"
    echo "- health results"
    echo "- config store"
    echo "- recent service logs"
    echo "- recent DevLog files"
    echo "- pip dependency list"
    echo "- network/port metadata"
    echo "- ownership/permission metadata"
    echo
    echo "EXCLUDES:"
    echo "- venv"
    echo "- __pycache__"
    echo "- pyc files"
    echo "- git metadata"
    echo "- generic cache/temp directories"

} > "$WORK/MANIFEST.txt"

find "$WORK" \
  -type f \
  -printf '%P\n' \
  | sort \
  > "$WORK/FILELIST.txt"

echo "[PASS] manifest"

echo
echo "===== 13. ARCHIVE ====="

tar \
  --numeric-owner \
  -C "$OUTROOT" \
  -czf "$ARCHIVE" \
  "$NAME"

echo "[PASS] archive created"

echo
echo "===== 14. SHA256 ====="

sha256sum "$ARCHIVE" \
  > "$SHA"

sha256sum -c "$SHA"

echo "[PASS] SHA256 verified"

echo
echo "===== AUTO CLEANUP WORK DIRECTORY ====="

if [ -d "$WORK" ]; then
    rm -rf -- "$WORK"
fi

echo "[PASS] temporary snapshot directory removed"

echo
echo "===== 15. SIZE ====="

SIZE="$(
  du -h "$ARCHIVE" \
    | awk '{print $1}'
)"

echo "SIZE=$SIZE"

echo
echo "===== 16. FINAL FILES ====="

ls -lh \
  "$ARCHIVE" \
  "$SHA"

echo
echo "============================================================"
echo " SNAPSHOT COMPLETE"
echo "============================================================"
echo "FOLDER=$OUTROOT"
echo "ARCHIVE=$ARCHIVE"
echo "SHA256=$SHA"
echo "SIZE=$SIZE"
echo "SOURCE_PROJECT_UNCHANGED=YES"
echo "SERVICES_RESTARTED=NO"
echo "============================================================"
