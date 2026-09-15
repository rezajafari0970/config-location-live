#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CORE="/opt/config-location"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

OUT="$DEV/panel-real-audit"

mkdir -p \
"$OUT" \
"$REPO/dev-context/panel-real-audit"


echo "=============================================="
echo " PHASE 25.3.1 EXISTING PANEL REAL AUDIT"
echo "=============================================="


echo "[1] Searching panel files..."

find "$CORE" \
-type f \
2>/dev/null \
| grep -Ei \
"panel|web|api|route|template|html|php|js|css|flask|fastapi|django" \
> "$OUT/panel-files.txt" || true



echo "[2] Searching routes and endpoints..."

grep -RIn \
-E "route|app\.get|app\.post|@.*route|/api|source|fetch" \
"$CORE" \
2>/dev/null \
> "$OUT/routes.txt" || true



echo "[3] Searching source management..."

grep -RIn \
-E "source|url|fetch|add|delete|enable|disable" \
"$CORE" \
2>/dev/null \
> "$OUT/source-management.txt" || true



echo "[4] Building audit JSON..."

python3 <<PY

import json,datetime


def read(path):

    try:
        return open(path).read().splitlines()

    except:
        return []


data={

"time":
datetime.datetime.now().astimezone().isoformat(),


"core":

"/opt/config-location",


"panel_files":

read("$OUT/panel-files.txt"),


"routes":

read("$OUT/routes.txt"),


"source_management":

read("$OUT/source-management.txt"),



"upgrade_rules":[

"modify_existing_panel",

"keep_current_ui",

"add_fetch_controls",

"connect_existing_backend"

]

}


json.dump(
data,
open(
"$OUT/panel-real-audit.json",
"w"
),
indent=2,
ensure_ascii=False
)

PY



echo "[5] Creating Upgrade Plan..."

cat >"$OUT/panel-upgrade-plan.json" <<JSON
{
"phase":"25.3.1",

"goal":

"upgrade existing fetch panel",


"new_sections":[

"fetch-settings",

"source-health",

"fetch-status",

"worker-control"

],


"rules":[

"no_second_panel",

"preserve_existing_routes",

"incremental_ui_upgrade"

]

}
JSON



echo "[6] Publish Dev Context..."

cp "$OUT/panel-real-audit.json" \
"$REPO/dev-context/panel-real-audit/panel-real-audit.json"

cp "$OUT/panel-upgrade-plan.json" \
"$REPO/dev-context/panel-real-audit/panel-upgrade-plan.json"



echo "[7] GitHub Sync..."

cd "$REPO"

git add dev-context/panel-real-audit


git commit \
-m "Phase 25.3.1 Existing Panel Real Audit $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25.3.1 COMPLETE"
echo "=============================================="

