#!/usr/bin/env bash
set -Eeuo pipefail

PHASE="phase3-pass0-health-integration-discovery"

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
echo " PHASE 3 PASS 0"
echo " HEALTH INTEGRATION DISCOVERY"
echo "================================================"

echo "START=$START"
echo "HOST=$(hostname)"

test -d "$PROJECT" || {
    fail "project directory missing"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "project python missing"
    exit 1
}

{
echo "================================================"
echo " CONFIG LOCATION"
echo " PHASE 3 PASS 0 — HEALTH DISCOVERY"
echo "================================================"

echo
echo "TIME=$(date -Is)"
echo "HOST=$(hostname)"


################################################
# 1 PROJECT STRUCTURE
################################################

echo
echo "========== [1] PROJECT STRUCTURE =========="

find "$PROJECT" \
    -maxdepth 4 \
    -type f \
    \( \
        -name '*.py' \
        -o -name '*.json' \
        -o -name '*.service' \
        -o -name '*.timer' \
        -o -name '*.sh' \
    \) \
    -print \
    | sort


################################################
# 2 HEALTH FILE DISCOVERY
################################################

echo
echo "========== [2] HEALTH-RELATED FILES =========="

find "$PROJECT" \
    -type f \
    | grep -Ei \
    'health|healthy|probe|test|checker|lifecycle|quarantine|publish|config' \
    | sort \
    || true


################################################
# 3 SYMBOL SEARCH
################################################

echo
echo "========== [3] HEALTH SYMBOL SEARCH =========="

grep -RnsI \
    --include='*.py' \
    -E \
    'health|healthy|unhealthy|health_check|check_health|probe|retest|retry|quarantine|candidate|publishable|last_health|tested_at|checked_at|next_check|latency|xray' \
    "$PROJECT/app" \
    2>/dev/null \
    || true


################################################
# 4 FUNCTIONS / CLASSES AST
################################################

echo
echo "========== [4] HEALTH FUNCTIONS / CLASSES =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import ast
import os
from pathlib import Path

root = Path(os.environ["PROJECT"]) / "app"

keywords = (
    "health",
    "check",
    "test",
    "probe",
    "retry",
    "retest",
    "quarantine",
    "publish",
    "lifecycle",
    "config",
)

for path in sorted(root.rglob("*.py")):
    try:
        text = path.read_text(
            encoding="utf-8",
            errors="replace",
        )
        tree = ast.parse(text)
    except Exception:
        continue

    matches = []

    for node in ast.walk(tree):
        if isinstance(
            node,
            (
                ast.FunctionDef,
                ast.AsyncFunctionDef,
                ast.ClassDef,
            ),
        ):
            name = node.name.lower()

            if any(k in name for k in keywords):
                matches.append(
                    (
                        node.lineno,
                        type(node).__name__,
                        node.name,
                    )
                )

    if matches:
        print()
        print("FILE:", path)

        for line, kind, name in sorted(matches):
            print(
                f"  {line:5d} {kind:18s} {name}"
            )
PY


################################################
# 5 IMPORT GRAPH
################################################

echo
echo "========== [5] HEALTH IMPORT GRAPH =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import ast
import os
from pathlib import Path

root = Path(os.environ["PROJECT"]) / "app"

health_terms = (
    "health",
    "lifecycle",
    "publish",
    "store",
    "state",
    "config",
)

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

    imports = []

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for item in node.names:
                imports.append(item.name)

        elif isinstance(node, ast.ImportFrom):
            mod = node.module or ""
            imports.append(mod)

    interesting = [
        x for x in imports
        if any(t in x.lower() for t in health_terms)
    ]

    if interesting:
        print()
        print("FILE:", path)

        for item in sorted(set(interesting)):
            print("  ->", item)
PY


################################################
# 6 STATE / STORAGE REFERENCES
################################################

echo
echo "========== [6] STATE / STORAGE REFERENCES =========="

grep -RnsI \
    --include='*.py' \
    -E \
    '/var/lib/config-location|sqlite|\.db|jsonl|state|store|storage|healthy|quarantine|publish|candidate|deleted|invalid' \
    "$PROJECT/app" \
    2>/dev/null \
    || true


################################################
# 7 FILESYSTEM STATE
################################################

echo
echo "========== [7] RUNTIME/PERSISTENT DATA =========="

for DIR in \
    /var/lib/config-location \
    /run/config-location \
    /var/log/config-location \
    "$PROJECT/data"
do
    echo
    echo "--- $DIR ---"

    if [ -e "$DIR" ]; then
        find "$DIR" \
            -maxdepth 4 \
            -printf '%y %u:%g %m %s %p\n' \
            2>/dev/null \
            | sort
    else
        echo "MISSING"
    fi
done


################################################
# 8 SYSTEMD
################################################

echo
echo "========== [8] SYSTEMD UNITS =========="

systemctl list-unit-files \
    --type=service \
    --type=timer \
    --no-pager \
    | grep -Ei \
    'config|health|location|fetch|country|publish|lifecycle' \
    || true

echo
echo "--- running relevant units ---"

systemctl list-units \
    --all \
    --no-pager \
    | grep -Ei \
    'config|health|location|fetch|country|publish|lifecycle' \
    || true


################################################
# 9 UNIT CONTENTS
################################################

echo
echo "========== [9] UNIT DEFINITIONS =========="

for UNIT in $(
    systemctl list-unit-files \
        --no-legend \
        | awk '{print $1}' \
        | grep -Ei \
        'config|health|location|fetch|country|publish|lifecycle'
); do

    echo
    echo "----- $UNIT -----"

    systemctl cat "$UNIT" \
        2>/dev/null \
        || true
done


################################################
# 10 PROCESSES
################################################

echo
echo "========== [10] PROCESSES =========="

ps auxww \
    | grep -Ei \
    'config-location|health|fetch|publish|lifecycle|country' \
    | grep -v grep \
    || true


################################################
# 11 SOCKETS
################################################

echo
echo "========== [11] LISTENING SOCKETS =========="

ss -lntup \
    || true


################################################
# 12 RECENT HEALTH LOGS
################################################

echo
echo "========== [12] RECENT HEALTH-RELATED JOURNAL =========="

journalctl \
    --since "-60 minutes" \
    --no-pager \
    2>/dev/null \
    | grep -Ei \
    'config-location|health|healthy|unhealthy|quarantine|publish|probe|xray|lifecycle' \
    | tail -n 500 \
    || true


################################################
# 13 HEALTH MODULE SOURCE EXCERPTS
################################################

echo
echo "========== [13] HEALTH SOURCE EXCERPTS =========="

FILES="$(
    grep -RIl \
        --include='*.py' \
        -E \
        'health|healthy|unhealthy|quarantine|probe|xray|publishable' \
        "$PROJECT/app" \
        2>/dev/null \
        | sort \
        | head -n 30
)"

for FILE in $FILES; do

    echo
    echo "################################################"
    echo "FILE: $FILE"
    echo "################################################"

    nl -ba "$FILE" \
        | sed -n '1,1200p'
done


################################################
# 14 SETTINGS HEALTH SECTION
################################################

echo
echo "========== [14] CENTRAL HEALTH SETTINGS =========="

cd "$PROJECT"

sudo -u configloc \
env PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json

from app.settings.engine import get_settings

s = get_settings()

print(
    json.dumps(
        {
            k: v
            for k, v in s.items()
            if any(
                x in k.lower()
                for x in (
                    "health",
                    "life",
                    "source",
                    "publish",
                    "cleanup",
                )
            )
        },
        indent=2,
        ensure_ascii=False,
    )
)
PY


################################################
# 15 CALL SITES
################################################

echo
echo "========== [15] HEALTH CALL SITES =========="

grep -RnsI \
    --include='*.py' \
    -E \
    '\b(run_health|health_check|check_health|probe_config|test_config|validate_config|quarantine|mark_healthy|mark_unhealthy|publish)\b' \
    "$PROJECT/app" \
    2>/dev/null \
    || true


################################################
# 16 DATABASE INSPECTION
################################################

echo
echo "========== [16] DATABASE FILES =========="

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
    | sort


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
        2>/dev/null
); do

    echo
    echo "----- DATABASE: $DB -----"

    "$PROJECT/venv/bin/python" - "$DB" <<'PY'
import sqlite3
import sys

db = sys.argv[1]

try:
    con = sqlite3.connect(
        f"file:{db}?mode=ro",
        uri=True,
    )

    rows = con.execute(
        """
        SELECT
            name,
            sql
        FROM sqlite_master
        WHERE type IN ('table','index','trigger','view')
        ORDER BY type, name
        """
    ).fetchall()

    for name, sql in rows:
        print()
        print("OBJECT:", name)
        print(sql or "")

except Exception as exc:
    print(
        "DB_INSPECT_ERROR:",
        repr(exc),
    )
PY

done


################################################
# 17 CURRENT COUNTS
################################################

echo
echo "========== [17] CURRENT HEALTH COUNTS =========="

grep -RnsI \
    --include='*.py' \
    -E \
    'healthy_count|quarantine_count|publishable_count|delete_candidate|recovered|stats' \
    "$PROJECT/app" \
    2>/dev/null \
    || true


################################################
# 18 SUMMARY MARKERS
################################################

echo
echo "========== [18] DISCOVERY MARKERS =========="

echo "DISCOVERY_COMPLETE"
echo
echo "No production source files were modified."
echo "No services were restarted."
echo "No config health state was changed."

} | tee "$DISCOVERY"

echo
echo "========== DISCOVERY FILE =========="
echo "$DISCOVERY"

echo
echo "========== VALIDATION =========="

test -s "$DISCOVERY" || {
    fail "discovery report empty"
    exit 1
}

grep -q 'DISCOVERY_COMPLETE' "$DISCOVERY" || {
    fail "discovery did not complete"
    exit 1
}

echo "DISCOVERY_VALID"

echo
echo "PHASE3_PASS0_SUCCESS"

RESULT="SUCCESS"
