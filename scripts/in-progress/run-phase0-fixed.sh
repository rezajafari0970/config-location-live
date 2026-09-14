#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/opt/config-location"
DATA="/var/lib/config-location"
ETC="/etc/config-location"
BASE="/root/3245"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$BASE/PHASE0-BASELINE-$TS"
REPORT="$OUT/reports/phase0-report.txt"

[ "$(id -u)" -eq 0 ] || {
  echo "ERROR: run as root"
  exit 1
}

rm -f /root/config-location-phase0-baseline.sh

mkdir -p "$BASE"

mkdir -p \
"$OUT/source" \
"$OUT/config" \
"$OUT/systemd" \
"$OUT/nginx" \
"$OUT/runtime" \
"$OUT/dependencies" \
"$OUT/tests" \
"$OUT/reports" \
"$OUT/critical-data"

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$REPORT"
}

log "PHASE 0 START"
log "Output: $OUT"

############################################################
# HOST / RESOURCE BASELINE
############################################################

{
  echo "===== DATE ====="
  date -Is

  echo
  echo "===== HOST ====="
  hostnamectl 2>&1 || true

  echo
  echo "===== OS ====="
  cat /etc/os-release 2>/dev/null || true

  echo
  echo "===== KERNEL ====="
  uname -a

  echo
  echo "===== CPU ====="
  nproc
  lscpu 2>/dev/null || true

  echo
  echo "===== MEMORY ====="
  free -h

  echo
  echo "===== DISK ====="
  df -hT

  echo
  echo "===== INODES ====="
  df -ih

} > "$OUT/reports/host.txt"

ROOT_USED="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
ROOT_FREE_KB="$(df -Pk / | awk 'NR==2 {print $4}')"
ROOT_FREE_GB=$((ROOT_FREE_KB / 1024 / 1024))

log "Disk used: ${ROOT_USED}%"
log "Disk free: ${ROOT_FREE_GB} GiB"

if [ "$ROOT_USED" -ge 95 ]; then
  log "ERROR: disk usage >=95%"
  exit 1
fi

if [ "$ROOT_FREE_GB" -lt 2 ]; then
  log "ERROR: less than 2 GiB free"
  exit 1
fi

############################################################
# PROJECT SOURCE
############################################################

log "Copying project source"

[ -d "$PROJECT" ] || {
  log "ERROR: $PROJECT not found"
  exit 1
}

rsync -aHAX \
  --numeric-ids \
  --exclude='venv/' \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='.git/' \
  "$PROJECT/" \
  "$OUT/source/"

############################################################
# CURRENT CONFIG
############################################################

log "Copying current config"

if [ -d "$ETC" ]; then
  rsync -aHAX --numeric-ids "$ETC/" "$OUT/config/"
fi

############################################################
# CRITICAL DATA
############################################################

log "Copying critical persistent data"

copy_dir() {
  SRC="$1"
  DST="$2"

  if [ -e "$SRC" ]; then
    mkdir -p "$(dirname "$DST")"
    rsync -aHAX --numeric-ids "$SRC" "$DST"
  fi
}

copy_dir "$DATA/sources" "$OUT/critical-data/sources"
copy_dir "$DATA/configs" "$OUT/critical-data/configs"
copy_dir "$DATA/source-snapshots" "$OUT/critical-data/source-snapshots"
copy_dir "$DATA/health-lifecycle" "$OUT/critical-data/health-lifecycle"
copy_dir "$DATA/country/country-identity" "$OUT/critical-data/country/country-identity"
copy_dir "$DATA/state" "$OUT/critical-data/state"

############################################################
# SYSTEMD
############################################################

log "Capturing systemd"

find \
  /etc/systemd/system \
  /usr/lib/systemd/system \
  /lib/systemd/system \
  -type f \
  \( -iname 'config-location*' -o -iname '*configloc*' \) \
  -print 2>/dev/null \
  | sort -u \
  > "$OUT/systemd/file-list.txt"

while IFS= read -r FILE; do
  [ -f "$FILE" ] || continue

  SAFE="$(echo "$FILE" | sed 's#/#__#g')"
  cp -a "$FILE" "$OUT/systemd/$SAFE"

done < "$OUT/systemd/file-list.txt"

{
  echo "===== UNIT FILES ====="
  systemctl list-unit-files --no-pager \
    | grep -Ei 'config-location|configloc' || true

  echo
  echo "===== UNITS ====="
  systemctl list-units --all --no-pager \
    | grep -Ei 'config-location|configloc' || true

} > "$OUT/systemd/unit-status.txt"

############################################################
# NGINX READ-ONLY
############################################################

log "Capturing nginx"

{
  echo "===== NGINX TEST ====="
  nginx -t 2>&1 || true

  echo
  echo "===== PORTS ====="
  ss -lntup || true

  echo
  echo "===== NGINX FULL CONFIG ====="
  nginx -T 2>&1 || true

} > "$OUT/nginx/nginx-current.txt"

############################################################
# DEPENDENCIES
############################################################

log "Capturing dependencies"

{
  echo "===== SYSTEM PYTHON ====="
  python3 --version 2>&1 || true
  command -v python3 || true

  echo
  echo "===== VENV PYTHON ====="

  if [ -x "$PROJECT/venv/bin/python" ]; then
    "$PROJECT/venv/bin/python" --version 2>&1 || true
    readlink -f "$PROJECT/venv/bin/python" || true
  fi

} > "$OUT/dependencies/python.txt"

if [ -x "$PROJECT/venv/bin/python" ]; then
  "$PROJECT/venv/bin/python" -m pip freeze \
    > "$OUT/dependencies/pip-freeze.txt" 2>&1 || true
fi

find "$PROJECT" \
  -maxdepth 2 \
  -type f \
  \( \
    -iname 'requirements*' \
    -o -iname 'pyproject.toml' \
    -o -iname 'Pipfile*' \
    -o -iname 'poetry.lock' \
  \) \
  -print \
  > "$OUT/dependencies/manifest-files.txt"

############################################################
# XRAY
############################################################

{
  echo "===== XRAY PATH ====="
  command -v xray || true

  echo
  echo "===== XRAY VERSION ====="
  xray version 2>&1 || true

} > "$OUT/dependencies/xray.txt"

############################################################
# SOURCE HASH INVENTORY
############################################################

log "Creating SHA256 inventory"

find "$OUT/source" -type f -print0 \
  | sort -z \
  | xargs -0 sha256sum \
  > "$OUT/reports/source-sha256.txt"

############################################################
# PYTHON SYNTAX
############################################################

log "Python syntax test"

PYTHON="$PROJECT/venv/bin/python"
[ -x "$PYTHON" ] || PYTHON="$(command -v python3)"

PY_FAIL=0

while IFS= read -r FILE; do
  if ! "$PYTHON" -m py_compile "$FILE" \
    >> "$OUT/tests/python-compile.log" 2>&1
  then
    echo "FAILED: $FILE" >> "$OUT/tests/python-compile-failed.txt"
    PY_FAIL=$((PY_FAIL + 1))
  fi
done < <(
  find \
    "$PROJECT/app" \
    "$PROJECT/scripts" \
    "$PROJECT/tests" \
    -type f \
    -name '*.py' \
    -not -path '*/venv/*' \
    -not -path '*/__pycache__/*' \
    2>/dev/null \
    | sort
)

echo "$PY_FAIL" > "$OUT/tests/python-compile-failure-count.txt"

############################################################
# SHELL SYNTAX
############################################################

log "Shell syntax test"

SH_FAIL=0

while IFS= read -r FILE; do
  if ! bash -n "$FILE" \
    >> "$OUT/tests/bash-syntax.log" 2>&1
  then
    echo "FAILED: $FILE" >> "$OUT/tests/bash-syntax-failed.txt"
    SH_FAIL=$((SH_FAIL + 1))
  fi
done < <(
  find "$PROJECT" \
    -type f \
    \( -name '*.sh' -o -path "$PROJECT/bin/*" \) \
    -not -path '*/venv/*' \
    2>/dev/null \
    | sort
)

echo "$SH_FAIL" > "$OUT/tests/bash-syntax-failure-count.txt"

############################################################
# RUNTIME
############################################################

log "Capturing runtime"

{
  echo "===== PROJECT PROCESSES ====="

  ps -eo pid,ppid,user,group,stat,etimes,%cpu,%mem,args \
    | grep -Ei \
    'config-location|configloc|app\.fetcher|app\.health|app\.country|app\.panel|xray' \
    | grep -v grep || true

  echo
  echo "===== PORTS ====="

  ss -lntup || true

} > "$OUT/runtime/processes-and-ports.txt"

############################################################
# RECENT ERRORS
############################################################

journalctl \
  --since "24 hours ago" \
  --no-pager 2>/dev/null \
  | grep -Ei \
  'config-location|configloc|No space left|Traceback|ERROR|CRITICAL' \
  | tail -n 5000 \
  > "$OUT/runtime/recent-errors.txt" || true

############################################################
# SUMMARY
############################################################

SOURCE_COUNT="$(find "$OUT/source" -type f | wc -l)"
CONFIG_COUNT="$(find "$OUT/critical-data/configs" -type f 2>/dev/null | wc -l || true)"

{
  echo "=================================================="
  echo "PHASE 0 BASELINE SUMMARY"
  echo "=================================================="
  echo
  echo "Timestamp: $TS"
  echo "Disk usage: ${ROOT_USED}%"
  echo "Disk free: ${ROOT_FREE_GB} GiB"
  echo "Python syntax failures: $PY_FAIL"
  echo "Shell syntax failures: $SH_FAIL"
  echo "Source files: $SOURCE_COUNT"
  echo "Config records: $CONFIG_COUNT"

} > "$OUT/reports/summary.txt"

############################################################
# PACK
############################################################

log "Packing baseline"

ARCHIVE="$OUT.tar.zst"

tar -cf - \
  -C "$BASE" \
  "$(basename "$OUT")" \
  | zstd -15 -T0 -o "$ARCHIVE"

sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

############################################################
# FINAL
############################################################

log "PHASE 0 COMPLETE"

echo
echo "============================================================"
echo "PHASE 0 COMPLETE"
echo "============================================================"
echo
cat "$OUT/reports/summary.txt"
echo
echo "Archive:"
echo "$ARCHIVE"
echo
echo "SHA256:"
echo "$ARCHIVE.sha256"
echo
ls -lh "$ARCHIVE" "$ARCHIVE.sha256"
