#!/usr/bin/env bash
set -Eeuo pipefail

MIRROR="/root/config-location-live-git"
DEV="/root/dev-scripts"

mkdir -p \
  "$DEV/in-progress" \
  "$DEV/reports" \
  "$DEV/summaries" \
  "$MIRROR/dev-observability/summaries"

echo "=============================================="
echo " CONFIG LOCATION FULL DEV AUTOMATION"
echo "=============================================="


################################################
# 1. LIVE LOG PUBLISHER — bounded
################################################

cat > /usr/local/sbin/config-location-live-log-publish <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

RUN_ID="${1:-}"
SRC="${2:-}"

[ -n "$RUN_ID" ]
[ -f "$SRC" ]

MIRROR="/root/config-location-live-git"

DST_DIR="$MIRROR/dev-observability/live/$RUN_ID"
DST="$DST_DIR/current.log"
TMP="$DST_DIR/.current.tmp"

mkdir -p "$DST_DIR"

python3 - "$SRC" "$TMP" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

# Maximum retained live terminal window.
MAX_LINES = 5000
MAX_CHARS = 1_000_000

text = src.read_text(
    encoding="utf-8",
    errors="replace",
)

lines = text.splitlines()

if len(lines) > MAX_LINES:
    lines = lines[-MAX_LINES:]

text = "\n".join(lines)

if len(text) > MAX_CHARS:
    text = text[-MAX_CHARS:]

patterns = [
    (
        r'ghp_[A-Za-z0-9]{20,}',
        '[REDACTED_GITHUB_TOKEN]',
    ),
    (
        r'github_pat_[A-Za-z0-9_]{20,}',
        '[REDACTED_GITHUB_TOKEN]',
    ),
    (
        r'AIza[0-9A-Za-z_-]{20,}',
        '[REDACTED_GOOGLE_KEY]',
    ),
    (
        r'(?i)(client_secret\s*[=:]\s*)[^\s"\']+',
        r'\1[REDACTED]',
    ),
    (
        r'(?i)(access[_-]?token\s*[=:]\s*)[^\s"\']+',
        r'\1[REDACTED]',
    ),
    (
        r'(?i)(refresh[_-]?token\s*[=:]\s*)[^\s"\']+',
        r'\1[REDACTED]',
    ),
    (
        r'(?i)(password\s*[=:]\s*)[^\s"\']+',
        r'\1[REDACTED]',
    ),
    (
        r'(?i)(secret\s*[=:]\s*)[^\s"\']+',
        r'\1[REDACTED]',
    ),
]

for pattern, replacement in patterns:
    text = re.sub(
        pattern,
        replacement,
        text,
    )

dst.write_text(
    text + "\n",
    encoding="utf-8",
)
PY

mv "$TMP" "$DST"

cd "$MIRROR"

git add \
  "dev-observability/live/$RUN_ID/current.log"

if git diff --cached --quiet; then
    exit 0
fi

git commit \
  -m "live-terminal: $RUN_ID"

if ! git push origin main; then
    git pull --rebase origin main
    git push origin main
fi
SCRIPT

chmod 0755 \
  /usr/local/sbin/config-location-live-log-publish


################################################
# 2. LIVE STREAM — lower commit frequency
################################################

cat > /usr/local/sbin/config-location-live-log-stream <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

RUN_ID="${1:-}"
SRC="${2:-}"
PID="${3:-}"

[ -n "$RUN_ID" ]
[ -n "$SRC" ]
[ -n "$PID" ]

while kill -0 "$PID" 2>/dev/null; do

    [ -f "$SRC" ] && \
    /usr/local/sbin/config-location-live-log-publish \
      "$RUN_ID" \
      "$SRC" \
      >/dev/null 2>&1 || true

    sleep 5
done

[ -f "$SRC" ] && \
/usr/local/sbin/config-location-live-log-publish \
  "$RUN_ID" \
  "$SRC" \
  >/dev/null 2>&1 || true
SCRIPT

chmod 0755 \
  /usr/local/sbin/config-location-live-log-stream


################################################
# 3. AUTO FINISH SUCCESSFUL DEV RUNS
################################################

python3 - <<'PY'
from pathlib import Path

p = Path(
    "/usr/local/sbin/config-location-dev-run"
)

s = p.read_text(
    encoding="utf-8"
)

if "AUTO_FINISH_ON_PASS=YES" not in s:

    old = '''    echo "DEV_RUN_RESULT=PASS"
    exit 0
fi
'''

    new = '''    echo "DEV_RUN_RESULT=PASS"
    echo "AUTO_FINISH_ON_PASS=YES"

    /usr/local/sbin/config-location-dev-finish \\
        "$SCRIPT" \\
        >/dev/null 2>&1 || true

    exit 0
fi
'''

    if old not in s:
        raise SystemExit(
            "DEV_RUN_PASS_BLOCK_NOT_FOUND"
        )

    s = s.replace(
        old,
        new,
        1,
    )

    p.write_text(
        s,
        encoding="utf-8",
    )

print(
    "AUTO_FINISH_PATCH=PASS"
)
PY


################################################
# 4. DEV SCRIPT MIRROR
################################################

cat > /usr/local/sbin/config-location-sync-dev-scripts <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

SRC="/root/dev-scripts/in-progress"
MIRROR="/root/config-location-live-git"
DST="$MIRROR/scripts/in-progress"

mkdir -p "$SRC" "$DST"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

find "$SRC" \
  -maxdepth 1 \
  -type f \
  -name '*.sh' \
  -print0 |
while IFS= read -r -d '' FILE; do

    NAME="$(basename "$FILE")"

    if grep -Eqi \
'(ghp_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|client_secret|access[_-]?token|refresh[_-]?token|private[_-]?key|password[[:space:]]*=)' \
      "$FILE"
    then
        echo "SKIP_SENSITIVE_SCRIPT=$NAME"
        continue
    fi

    cp -a \
      "$FILE" \
      "$TMP/$NAME"
done

rsync \
  -a \
  --delete \
  "$TMP/" \
  "$DST/"

cd "$MIRROR"

git add -A scripts/in-progress

if git diff --cached --quiet; then
    exit 0
fi

git commit \
  -m "dev-scripts: automatic sync"

if ! git push origin main; then
    git pull --rebase origin main
    git push origin main
fi
SCRIPT

chmod 0755 \
  /usr/local/sbin/config-location-sync-dev-scripts


################################################
# 5. REPORT SUMMARY ARCHIVER
################################################

cat > /usr/local/sbin/config-location-dev-summary <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

REPORT="${1:-}"

[ -d "$REPORT" ] || exit 0

NAME="$(basename "$REPORT")"

SRC="$REPORT/result.json"

[ -f "$SRC" ] || exit 0

LOCAL="/root/dev-scripts/summaries"
MIRROR="/root/config-location-live-git"
REMOTE="$MIRROR/dev-observability/summaries"

mkdir -p "$LOCAL" "$REMOTE"

cp -a \
  "$SRC" \
  "$LOCAL/${NAME}.json"

cp -a \
  "$SRC" \
  "$REMOTE/${NAME}.json"

cd "$MIRROR"

git add \
  "dev-observability/summaries/${NAME}.json"

if git diff --cached --quiet; then
    exit 0
fi

git commit \
  -m "dev-summary: $NAME"

git push origin main
SCRIPT

chmod 0755 \
  /usr/local/sbin/config-location-dev-summary


################################################
# 6. CLEANUP ENGINE
################################################

cat > /usr/local/sbin/config-location-dev-cleanup <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

MIRROR="/root/config-location-live-git"

LOCAL_LIVE="/root/dev-scripts/live"
LOCAL_REPORTS="/root/dev-scripts/reports"

REMOTE_LIVE="$MIRROR/dev-observability/live"
REMOTE_REPORTS="$MIRROR/dev-observability/reports"

mkdir -p \
  "$LOCAL_LIVE" \
  "$LOCAL_REPORTS" \
  "$REMOTE_LIVE" \
  "$REMOTE_REPORTS"


##############################################
# Preserve tiny summaries before deleting
# reports.
##############################################

find "$LOCAL_REPORTS" \
  -mindepth 1 \
  -maxdepth 1 \
  -type d \
  -mmin +60 \
  -print0 |
while IFS= read -r -d '' REPORT; do

    /usr/local/sbin/config-location-dev-summary \
      "$REPORT" \
      >/dev/null 2>&1 || true

done


##############################################
# Live sessions:
# remove after 6 hours.
##############################################

find "$LOCAL_LIVE" \
  -mindepth 1 \
  -maxdepth 1 \
  -type d \
  -mmin +360 \
  -exec rm -rf {} + \
  2>/dev/null || true


find "$REMOTE_LIVE" \
  -mindepth 1 \
  -maxdepth 1 \
  -type d \
  -mmin +360 \
  -exec rm -rf {} + \
  2>/dev/null || true


##############################################
# Detailed evidence:
# retain for 7 days.
##############################################

find "$LOCAL_REPORTS" \
  -mindepth 1 \
  -maxdepth 1 \
  -type d \
  -mtime +7 \
  -exec rm -rf {} + \
  2>/dev/null || true


find "$REMOTE_REPORTS" \
  -mindepth 1 \
  -maxdepth 1 \
  -type d \
  -mtime +7 \
  -exec rm -rf {} + \
  2>/dev/null || true


##############################################
# Also cap detailed reports to newest 50.
##############################################

mapfile -t OLD_REPORTS < <(
    find "$LOCAL_REPORTS" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      -printf '%T@ %p\n' |
    sort -nr |
    tail -n +51 |
    cut -d' ' -f2-
)

for DIR in "${OLD_REPORTS[@]}"; do
    rm -rf "$DIR"
done


mapfile -t OLD_REMOTE < <(
    find "$REMOTE_REPORTS" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      -printf '%T@ %p\n' |
    sort -nr |
    tail -n +51 |
    cut -d' ' -f2-
)

for DIR in "${OLD_REMOTE[@]}"; do
    rm -rf "$DIR"
done


##############################################
# Remove finished scripts from GitHub mirror.
##############################################

/usr/local/sbin/config-location-sync-dev-scripts \
  >/dev/null 2>&1 || true


##############################################
# Commit cleanup.
##############################################

cd "$MIRROR"

git add -A \
  dev-observability \
  scripts/in-progress

if ! git diff --cached --quiet; then

    git commit \
      -m "maintenance: automatic dev cleanup"

    if ! git push origin main; then
        git pull --rebase origin main
        git push origin main
    fi

fi

echo "DEV_CLEANUP=PASS"
SCRIPT

chmod 0755 \
  /usr/local/sbin/config-location-dev-cleanup


################################################
# 7. SYSTEMD PATH FOR DEV SCRIPTS
################################################

cat > /etc/systemd/system/config-location-dev-script-sync.service <<'UNIT'
[Unit]
Description=Config Location Development Script Git Sync
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/config-location-sync-dev-scripts
User=root
UNIT


cat > /etc/systemd/system/config-location-dev-script-sync.path <<'UNIT'
[Unit]
Description=Watch Config Location Development Scripts

[Path]
PathChanged=/root/dev-scripts/in-progress
PathModified=/root/dev-scripts/in-progress

[Install]
WantedBy=multi-user.target
UNIT


################################################
# 8. AUTOMATIC CLEANUP TIMER
################################################

cat > /etc/systemd/system/config-location-dev-cleanup.service <<'UNIT'
[Unit]
Description=Config Location Development Cleanup

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/config-location-dev-cleanup
User=root
UNIT


cat > /etc/systemd/system/config-location-dev-cleanup.timer <<'UNIT'
[Unit]
Description=Config Location Development Cleanup Timer

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
AccuracySec=2min
Persistent=true

[Install]
WantedBy=timers.target
UNIT


################################################
# 9. WEEKLY LOCAL GIT GC
################################################

cat > /etc/systemd/system/config-location-git-gc.service <<'UNIT'
[Unit]
Description=Config Location Mirror Git Maintenance

[Service]
Type=oneshot
User=root
WorkingDirectory=/root/config-location-live-git
ExecStart=/usr/bin/git gc --auto
UNIT


cat > /etc/systemd/system/config-location-git-gc.timer <<'UNIT'
[Unit]
Description=Weekly Config Location Git Maintenance

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
UNIT


################################################
# 10. START EVERYTHING
################################################

bash -n \
  /usr/local/sbin/config-location-dev-run

bash -n \
  /usr/local/sbin/config-location-live-log-publish

bash -n \
  /usr/local/sbin/config-location-live-log-stream

bash -n \
  /usr/local/sbin/config-location-sync-dev-scripts

bash -n \
  /usr/local/sbin/config-location-dev-summary

bash -n \
  /usr/local/sbin/config-location-dev-cleanup


systemctl daemon-reload

systemctl enable --now \
  config-location-dev-script-sync.path

systemctl enable --now \
  config-location-dev-cleanup.timer

systemctl enable --now \
  config-location-git-gc.timer


/usr/local/sbin/config-location-sync-dev-scripts || true

/usr/local/sbin/config-location-dev-cleanup || true


echo
echo "=============================================="
echo " FULL DEV AUTOMATION READY"
echo "=============================================="

echo "SOURCE_SYNC=AUTOMATIC"
echo "DEV_SCRIPT_SYNC=AUTOMATIC"
echo "CHECKPOINT=AUTOMATIC_ON_DEV_RUN"
echo "LIVE_TERMINAL=AUTOMATIC_ON_DEV_RUN"
echo "DIFF_EVIDENCE=AUTOMATIC"
echo "QUICK_REGRESSION=AUTOMATIC"
echo "REPORT_PUBLISH=AUTOMATIC"

echo "PASS_SCRIPT_AUTO_DELETE=YES"
echo "FAILED_SCRIPT_KEEP=YES"

echo "LIVE_LOG_RETENTION=6_HOURS"
echo "FULL_REPORT_RETENTION=7_DAYS"
echo "MAX_FULL_REPORTS=50"
echo "RESULT_SUMMARIES=RETAINED"

echo "CLEANUP_INTERVAL=1_HOUR"
echo "LOCAL_GIT_GC=WEEKLY"

echo
echo "CONFIG_LOCATION_FULL_DEV_AUTOMATION_SUCCESS"
