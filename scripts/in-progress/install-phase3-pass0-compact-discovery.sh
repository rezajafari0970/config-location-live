#!/usr/bin/env bash
set -Eeu

PHASE="phase3-pass0-compact-health-discovery"

PROJECT="/opt/config-location"
REPO="/root/project-log"

TS="$(date +%Y%m%d-%H%M%S)"
DATE="$(date +%Y-%m-%d)"
START="$(date -Is)"

RUN_DIR="$REPO/executions/$DATE"
REPORT_DIR="$REPO/reports"
DISCOVERY_DIR="$REPO/discovery/$DATE"

LOG="$RUN_DIR/${PHASE}-${TS}.log"
REPORT="$REPORT_DIR/${PHASE}-${TS}.txt"
DISCOVERY="$DISCOVERY_DIR/${PHASE}-${TS}.txt"

mkdir -p \
  "$RUN_DIR" \
  "$REPORT_DIR" \
  "$DISCOVERY_DIR"

RESULT="SUCCESS"
ERRORS=""

exec 3> >(tee -a "$LOG")
exec 1>&3 2>&1

fail() {
    RESULT="FAILED"
    ERRORS="${ERRORS}\n$1"
    echo "ERROR: $1"
}

finish() {
    CODE=$?

    if [ "$CODE" -ne 0 ]; then
        RESULT="FAILED"
        ERRORS="${ERRORS}\nscript exit code $CODE"
    fi

    echo
    echo "========== FINAL =========="
    echo "RESULT=$RESULT"
    echo "END=$(date -Is)"

    cat > "$REPORT" <<REPORT
CONFIG LOCATION REPORT

Phase:
$PHASE

Result:
$RESULT

Start:
$START

End:
$(date -Is)

Discovery:
$DISCOVERY

Discovery size:
$(du -h "$DISCOVERY" 2>/dev/null | awk '{print $1}')

Log:
$LOG

Errors:
$ERRORS
REPORT

    exec 1>&-
    exec 2>&-
    exec 3>&-

    sleep 1

    cd "$REPO"

    git add \
      "$LOG" \
      "$REPORT" \
      "$DISCOVERY" \
      >/dev/null 2>&1 || true

    if ! git diff --cached --quiet; then
        git commit \
          -m "Phase execution $PHASE $TS" \
          >/dev/null 2>&1 || true
    fi

    git push origin main >/dev/null 2>&1 || true

    if [ "$RESULT" != "SUCCESS" ]; then
        exit 1
    fi
}

trap finish EXIT

echo "================================================"
echo " PHASE 3 PASS 0 COMPACT"
echo " HEALTH INTEGRATION DISCOVERY"
echo "================================================"

test -d "$PROJECT" || {
    fail "project directory missing"
    exit 1
}

{
echo "================================================"
echo " CONFIG LOCATION"
echo " COMPACT HEALTH DISCOVERY"
echo "================================================"

echo "TIME=$(date -Is)"
echo "HOST=$(hostname)"

echo
echo "========== [1] HEALTH-RELATED SOURCE FILES =========="

find "$PROJECT/app" \
  -type f \
  -name '*.py' \
  | grep -Ei \
  'health|lifecycle|publish|quarantine|state|worker|tracker|country' \
  | sort \
  | head -n 250

echo
echo "========== [2] HEALTH SYMBOLS =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'def .*health|async def .*health|def .*probe|async def .*probe|def .*publish|async def .*publish|def .*quarantine|def .*lifecycle|last_health|healthy|unhealthy|retest|next_check' \
  "$PROJECT/app" \
  2>/dev/null \
  | head -n 1200 || true

echo
echo "========== [3] AST FUNCTIONS / CLASSES =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import ast
import os
from pathlib import Path

root = Path(os.environ["PROJECT"]) / "app"

terms = (
    "health",
    "probe",
    "test",
    "check",
    "retest",
    "publish",
    "quarantine",
    "lifecycle",
    "tracker",
)

count = 0

for path in sorted(root.rglob("*.py")):
    try:
        tree = ast.parse(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        continue

    rows = []

    for node in ast.walk(tree):
        if isinstance(
            node,
            (
                ast.FunctionDef,
                ast.AsyncFunctionDef,
                ast.ClassDef,
            ),
        ):
            low = node.name.lower()

            if any(t in low for t in terms):
                rows.append(
                    (
                        node.lineno,
                        type(node).__name__,
                        node.name,
                    )
                )

    if rows:
        print()
        print(f"FILE: {path}")

        for line, kind, name in sorted(rows):
            print(f"{line:5d} {kind:18s} {name}")

            count += 1

            if count >= 1000:
                raise SystemExit
PY

echo
echo "========== [4] HEALTH IMPORT GRAPH =========="

grep -RnsI \
  --include='*.py' \
  -E \
  '^from .*health|^import .*health|^from .*publish|^from .*lifecycle|^from .*state|^from .*tracker' \
  "$PROJECT/app" \
  2>/dev/null \
  | head -n 800 || true

echo
echo "========== [5] RUNTIME STATE TOP-LEVEL =========="

for DIR in \
  /var/lib/config-location \
  /run/config-location \
  /var/log/config-location
do
    echo
    echo "--- $DIR ---"

    if [ -d "$DIR" ]; then
        find "$DIR" \
          -mindepth 1 \
          -maxdepth 2 \
          -printf '%y %u:%g %m %s %p\n' \
          2>/dev/null \
          | sort \
          | head -n 800
    else
        echo "MISSING"
    fi
done

echo
echo "========== [6] LARGE STATE DIRECTORY SUMMARY =========="

for DIR in \
  /var/lib/config-location/country \
  /var/lib/config-location/health \
  /var/lib/config-location/lifecycle \
  /var/lib/config-location/publish \
  /var/lib/config-location/state
do
    if [ -d "$DIR" ]; then
        echo
        echo "--- $DIR ---"
        du -sh "$DIR" 2>/dev/null || true
        echo "files=$(find "$DIR" -type f 2>/dev/null | wc -l)"
        echo "dirs=$(find "$DIR" -type d 2>/dev/null | wc -l)"
    fi
done

echo
echo "========== [7] SYSTEMD RELEVANT UNITS =========="

systemctl list-unit-files \
  --no-pager \
  | grep -Ei \
  'config-location|health|lifecycle|publish|fetch|country' \
  | head -n 200 || true

echo
echo "========== [8] SYSTEMD UNIT CONTENT =========="

for UNIT in $(
    systemctl list-unit-files \
      --no-legend \
      | awk '{print $1}' \
      | grep -Ei \
      'config-location|health|lifecycle|publish|fetch|country' \
      | head -n 80
); do
    echo
    echo "----- $UNIT -----"
    systemctl cat "$UNIT" 2>/dev/null | head -n 200 || true
done

echo
echo "========== [9] PROCESSES =========="

ps auxww \
  | grep -Ei \
  'config-location|health|lifecycle|publish|fetch|country' \
  | grep -v grep \
  | head -n 200 || true

echo
echo "========== [10] CENTRAL SETTINGS =========="

cd "$PROJECT"

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json
from app.settings.engine import get_settings

s = get_settings()

keys = {
    "source_intelligence",
    "health_retest",
    "config_lifetime",
    "country",
    "subscription",
    "cleanup",
    "resource_guardian",
}

print(
    json.dumps(
        {
            k: v
            for k, v in s.items()
            if k in keys
        },
        ensure_ascii=False,
        indent=2,
    )
)
PY

echo
echo "========== [11] HEALTH CALL SITES =========="

grep -RnsI \
  --include='*.py' \
  -E \
  '\b(health|probe|check_health|run_health|publishable_config_ids|build_publish_snapshot|quarantine|lifecycle|tracker)\b' \
  "$PROJECT/app" \
  2>/dev/null \
  | head -n 1500 || true

echo
echo "========== [12] DATABASE FILES =========="

find \
  /var/lib/config-location \
  "$PROJECT" \
  -type f \
  \( \
    -name '*.db' \
    -o -name '*.sqlite' \
    -o -name '*.sqlite3' \
  \) \
  -print \
  2>/dev/null \
  | head -n 100

echo
echo "========== [13] DATABASE SCHEMA =========="

for DB in $(
    find \
      /var/lib/config-location \
      "$PROJECT" \
      -type f \
      \( \
        -name '*.db' \
        -o -name '*.sqlite' \
        -o -name '*.sqlite3' \
      \) \
      -print \
      2>/dev/null \
      | head -n 20
); do

    echo
    echo "----- DB: $DB -----"

    "$PROJECT/venv/bin/python" - "$DB" <<'PY'
import sqlite3
import sys

db = sys.argv[1]

try:
    con = sqlite3.connect(
        f"file:{db}?mode=ro",
        uri=True,
    )

    for name, sql in con.execute(
        """
        SELECT name, sql
        FROM sqlite_master
        WHERE type IN ('table','index','trigger','view')
        ORDER BY type, name
        LIMIT 300
        """
    ):
        print()
        print("OBJECT:", name)
        print(sql or "")

except Exception as exc:
    print("DB_INSPECT_ERROR:", repr(exc))
PY

done

echo
echo "========== [14] SELECTED SOURCE EXCERPTS =========="

FILES="$(
    grep -RIl \
      --include='*.py' \
      -E \
      'publishable_config_ids|health|quarantine|probe|lifecycle' \
      "$PROJECT/app" \
      2>/dev/null \
      | sort \
      | head -n 18
)"

for FILE in $FILES; do
    echo
    echo "################################################"
    echo "FILE: $FILE"
    echo "################################################"

    grep -n \
      -E \
      'health|probe|quarantine|publishable|lifecycle|retest|last_health|next_check' \
      "$FILE" \
      2>/dev/null \
      | head -n 120 \
      | while IFS=: read -r LINE REST; do
            START_LINE=$((LINE-8))
            [ "$START_LINE" -lt 1 ] && START_LINE=1
            END_LINE=$((LINE+20))

            echo
            echo "--- lines $START_LINE-$END_LINE ---"

            sed -n "${START_LINE},${END_LINE}p" "$FILE"
        done
done

echo
echo "========== [15] RECENT JOURNAL SUMMARY =========="

journalctl \
  --since "-30 minutes" \
  --no-pager \
  2>/dev/null \
  | grep -Ei \
  'config-location|health|healthy|unhealthy|quarantine|publish|probe|lifecycle|xray' \
  | tail -n 400 || true

echo
echo "========== [16] DISCOVERY COMPLETE =========="

echo "NO_PRODUCTION_CHANGES=true"
echo "NO_SERVICE_RESTART=true"
echo "NO_HEALTH_STATE_CHANGE=true"
echo "DISCOVERY_COMPLETE"

} > "$DISCOVERY"

echo
echo "========== DISCOVERY SIZE =========="

du -h "$DISCOVERY"
wc -l "$DISCOVERY"

SIZE_BYTES="$(stat -c '%s' "$DISCOVERY")"

MAX_BYTES=$((20 * 1024 * 1024))

if [ "$SIZE_BYTES" -gt "$MAX_BYTES" ]; then
    fail "compact discovery exceeded 20MB"
    exit 1
fi

grep -q 'DISCOVERY_COMPLETE' "$DISCOVERY" || {
    fail "discovery incomplete"
    exit 1
}

echo "DISCOVERY_VALID"
echo "PHASE3_PASS0_COMPACT_SUCCESS"

RESULT="SUCCESS"
