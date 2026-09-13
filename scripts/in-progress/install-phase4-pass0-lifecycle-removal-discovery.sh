#!/usr/bin/env bash
set -Eeu

PHASE="phase4-pass0-lifecycle-removal-discovery"

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
        ERRORS="${ERRORS}\nexit code $CODE"
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

Mode:
READ ONLY DISCOVERY

Production changes:
NONE

Service restart:
NONE

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

    cd "$REPO" || exit 1

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

    [ "$RESULT" = "SUCCESS" ] || exit 1
}

trap finish EXIT


echo "================================================"
echo " PHASE 4 PASS 0"
echo " LIFECYCLE / REMOVAL DISCOVERY"
echo "================================================"


################################################
# 1 PRECHECK
################################################

echo
echo "========== [1/14] PRECHECK =========="

test -d "$PROJECT/app" || {
    fail "project app missing"
    exit 1
}

test -x "$PROJECT/venv/bin/python" || {
    fail "venv missing"
    exit 1
}

echo "PRECHECK_OK"


################################################
# DISCOVERY
################################################

{
echo "================================================"
echo " CONFIG LOCATION"
echo " PHASE 4 LIFECYCLE / REMOVAL DISCOVERY"
echo "================================================"

echo "TIME=$(date -Is)"
echo "HOST=$(hostname)"


################################################
# 2 MODULE FILES
################################################

echo
echo "========== [2] RELEVANT MODULE FILES =========="

find "$PROJECT/app" \
  -type f \
  -name '*.py' \
  | grep -Ei \
  'lifecycle|removal|remove|cleanup|quarantine|expire|lifetime|publish|country|orphan|retention' \
  | sort \
  | head -n 400 || true


################################################
# 3 SYMBOLS
################################################

echo
echo "========== [3] FUNCTIONS / CLASSES =========="

PROJECT="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import ast
import os
from pathlib import Path

root=Path(os.environ["PROJECT"]) / "app"

terms=(
    "lifecycle",
    "remove",
    "removal",
    "cleanup",
    "quarantine",
    "expire",
    "expiry",
    "lifetime",
    "publish",
    "country",
    "orphan",
    "retention",
)

count=0

for path in sorted(root.rglob("*.py")):
    try:
        tree=ast.parse(
            path.read_text(
                encoding="utf-8",
                errors="replace",
            )
        )
    except Exception:
        continue

    rows=[]

    for node in ast.walk(tree):
        if isinstance(
            node,
            (
                ast.FunctionDef,
                ast.AsyncFunctionDef,
                ast.ClassDef,
            ),
        ):
            low=node.name.lower()

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
        print("FILE:",path)

        for line,kind,name in sorted(rows):
            print(
                f"{line:5d} "
                f"{kind:18s} "
                f"{name}"
            )

            count += 1

            if count >= 1200:
                raise SystemExit
PY


################################################
# 4 CALL SITES
################################################

echo
echo "========== [4] CALL SITES =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'quarantine|remove_config|delete_config|expire|expired|lifetime|cleanup|orphan|publishable_config_ids|country.*healthy|health.*unhealthy|removal' \
  "$PROJECT/app" \
  2>/dev/null \
  | head -n 1800 || true


################################################
# 5 CENTRAL SETTINGS
################################################

echo
echo "========== [5] CENTRAL SETTINGS =========="

cd "$PROJECT"

PYTHONPATH="$PROJECT" \
"$PROJECT/venv/bin/python" - <<'PY'
import json
from app.settings.engine import get_settings

s=get_settings()

wanted={}

for key in (
    "config_lifetime",
    "cleanup",
    "removal",
    "publish",
    "country",
    "health",
    "features",
):
    if key in s:
        wanted[key]=s[key]

print(
    json.dumps(
        wanted,
        ensure_ascii=False,
        indent=2,
    )
)
PY


################################################
# 6 SETTINGS STATIC MATCHES
################################################

echo
echo "========== [6] SETTINGS CONTRACT MATCHES =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'config_lifetime|lifetime_hours|expire|expiration|cleanup|removal|quarantine|retention|orphan' \
  "$PROJECT/app/settings" \
  "$PROJECT/app/panel" \
  2>/dev/null \
  | head -n 1200 || true


################################################
# 7 LIFECYCLE SOURCE EXCERPTS
################################################

echo
echo "========== [7] LIFECYCLE SOURCE EXCERPTS =========="

FILES="$(
    grep -RIl \
      --include='*.py' \
      -E \
      'quarantine|lifecycle|remove|cleanup|expire|lifetime|retention|orphan' \
      "$PROJECT/app" \
      2>/dev/null \
      | sort \
      | head -n 24
)"

for FILE in $FILES; do
    echo
    echo "################################################"
    echo "FILE: $FILE"
    echo "################################################"

    grep -n \
      -E \
      'quarantine|lifecycle|remove|cleanup|expire|lifetime|retention|orphan' \
      "$FILE" \
      2>/dev/null \
      | head -n 120 \
      | while IFS=: read -r LINE REST; do

            START_LINE=$((LINE-8))
            [ "$START_LINE" -lt 1 ] && START_LINE=1
            END_LINE=$((LINE+22))

            echo
            echo "--- lines $START_LINE-$END_LINE ---"

            sed -n "${START_LINE},${END_LINE}p" "$FILE"

        done
done


################################################
# 8 RUNTIME STATE
################################################

echo
echo "========== [8] RUNTIME STATE =========="

for DIR in \
  /var/lib/config-location/lifecycle \
  /var/lib/config-location/quarantine \
  /var/lib/config-location/removal \
  /var/lib/config-location/cleanup \
  /var/lib/config-location/configs \
  /var/lib/config-location/country \
  /var/lib/config-location/publish
do
    echo
    echo "--- $DIR ---"

    if [ -d "$DIR" ]; then
        du -sh "$DIR" 2>/dev/null || true

        echo "files=$(
            find "$DIR" -type f 2>/dev/null | wc -l
        )"

        echo "dirs=$(
            find "$DIR" -type d 2>/dev/null | wc -l
        )"

        find "$DIR" \
          -mindepth 1 \
          -maxdepth 2 \
          -printf '%y %u:%g %m %s %p\n' \
          2>/dev/null \
          | sort \
          | head -n 300
    else
        echo "MISSING"
    fi
done


################################################
# 9 SAMPLE STATE JSON STRUCTURE
################################################

echo
echo "========== [9] SAMPLE STATE STRUCTURES =========="

"$PROJECT/venv/bin/python" - <<'PY'
import json
from pathlib import Path

roots=[
    Path("/var/lib/config-location/lifecycle"),
    Path("/var/lib/config-location/quarantine"),
    Path("/var/lib/config-location/removal"),
    Path("/var/lib/config-location/cleanup"),
]

seen=0

for root in roots:
    if not root.exists():
        continue

    for p in root.rglob("*.json"):
        try:
            if p.stat().st_size > 2_000_000:
                continue

            data=json.loads(
                p.read_text(
                    encoding="utf-8",
                    errors="replace",
                )
            )
        except Exception:
            continue

        print()
        print("FILE:",p)

        if isinstance(data,dict):
            print(
                "TOP_KEYS:",
                sorted(data.keys()),
            )

            for key in (
                "config_id",
                "state",
                "reason",
                "created_at",
                "updated_at",
                "expires_at",
                "quarantined_at",
                "removed_at",
                "health_state",
                "consecutive_failures",
            ):
                if key in data:
                    v=data[key]
                    print(
                        f"{key}={v!r}"
                    )

        elif isinstance(data,list):
            print(
                "LIST_LENGTH:",
                len(data),
            )

            if data and isinstance(data[0],dict):
                print(
                    "FIRST_KEYS:",
                    sorted(data[0].keys()),
                )

        seen += 1

        if seen >= 20:
            raise SystemExit
PY


################################################
# 10 SYSTEMD
################################################

echo
echo "========== [10] SYSTEMD UNITS =========="

systemctl list-unit-files \
  --no-pager \
  | grep -Ei \
  'config-location.*(lifecycle|cleanup|removal|quarantine)|(?:lifecycle|cleanup|removal|quarantine).*config-location' \
  || true

for UNIT in $(
    systemctl list-unit-files \
      --no-legend \
      | awk '{print $1}' \
      | grep -Ei \
      'config-location.*(lifecycle|cleanup|removal|quarantine)|(?:lifecycle|cleanup|removal|quarantine).*config-location'
); do

    echo
    echo "----- $UNIT -----"

    systemctl cat "$UNIT" \
      2>/dev/null \
      | head -n 240 || true

    systemctl status "$UNIT" \
      --no-pager \
      -l \
      2>/dev/null \
      | head -n 80 || true
done


################################################
# 11 PUBLISH INTERACTION
################################################

echo
echo "========== [11] PUBLISH INTERACTION =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'publishable_config_ids|quarantine|expired|removed|lifecycle|healthy' \
  "$PROJECT/app/publish" \
  2>/dev/null \
  | head -n 800 || true

if [ -f "$PROJECT/app/publish/filter.py" ]; then
    echo
    echo "--- publish/filter.py ---"

    nl -ba "$PROJECT/app/publish/filter.py" \
      | sed -n '1,420p'
fi


################################################
# 12 COUNTRY INTERACTION
################################################

echo
echo "========== [12] COUNTRY INTERACTION =========="

grep -RnsI \
  --include='*.py' \
  -E \
  'healthy|unhealthy|quarantine|removed|expired|lifecycle|config_id' \
  "$PROJECT/app/country" \
  2>/dev/null \
  | head -n 900 || true


################################################
# 13 RECENT JOURNAL
################################################

echo
echo "========== [13] RECENT JOURNAL =========="

journalctl \
  --since "-45 minutes" \
  --no-pager \
  2>/dev/null \
  | grep -Ei \
  'config-location|lifecycle|quarantine|remove|cleanup|expire|expired|orphan|publish' \
  | tail -n 500 || true


################################################
# 14 QUESTIONS
################################################

echo
echo "========== [14] PHASE 4 CONTRACT QUESTIONS =========="

cat <<'QUESTIONS'
Q1. What is the canonical lifecycle state object?
Q2. Where is lifecycle state persisted?
Q3. What event/function moves a config into quarantine?
Q4. What event/function permanently removes a config?
Q5. Is removal based on age, health failures, or both?
Q6. What exact timestamp is used for config lifetime?
Q7. Is lifetime measured from first_seen, fetched_at, created_at, or another field?
Q8. Is config_lifetime already wired to Central Settings?
Q9. What consecutive-failure rule exists before quarantine/removal?
Q10. Does Publish immediately exclude quarantined/expired/removed configs?
Q11. Does Country clean state when a config is removed?
Q12. What cleanup jobs already remove orphan state/history?
Q13. What systemd service owns lifecycle/removal today?
Q14. Is there a lock/cursor preventing duplicate removals?
Q15. What is the safest insertion point for a real lifecycle engine?
QUESTIONS

echo
echo "NO_PRODUCTION_CHANGES=true"
echo "NO_CONFIG_DELETE=true"
echo "NO_STATE_MUTATION=true"
echo "NO_SERVICE_RESTART=true"
echo "PHASE4_PASS0_DISCOVERY_COMPLETE"

} > "$DISCOVERY"


################################################
# VALIDATION
################################################

echo
echo "========== DISCOVERY VALIDATION =========="

test -s "$DISCOVERY" || {
    fail "discovery empty"
    exit 1
}

SIZE="$(stat -c '%s' "$DISCOVERY")"

if [ "$SIZE" -gt $((12*1024*1024)) ]; then
    fail "discovery exceeded 12MB"
    exit 1
fi

grep -q \
  'PHASE4_PASS0_DISCOVERY_COMPLETE' \
  "$DISCOVERY" || {
    fail "discovery incomplete"
    exit 1
}

du -h "$DISCOVERY"
wc -l "$DISCOVERY"

echo "DISCOVERY_VALID"
echo "PHASE4_PASS0_SUCCESS"

RESULT="SUCCESS"
