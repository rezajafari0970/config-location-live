#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CORE="/opt/config-location"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

OUT="$DEV/fetch-panel-integration"

mkdir -p \
"$OUT" \
"$REPO/dev-context/fetch-panel-integration"


echo "=============================================="
echo " PHASE 25.2.1 FETCH + PANEL INTEGRATION AUDIT"
echo "=============================================="


echo "[1] Snapshot..."

tar czf \
"$OUT/pre-fetch-panel-$(date +%Y%m%d-%H%M%S).tar.gz" \
"$CORE" \
2>/dev/null || true


echo "[2] Fetch files..."

find "$CORE" \
-type f \
2>/dev/null |
grep -Ei \
"fetch|source|collector|subscription|worker" \
> "$OUT/fetch-files.txt" || true


echo "[3] Panel files..."

find "$CORE" \
-type f \
2>/dev/null |
grep -Ei \
"panel|web|api|route|template|html|flask|fastapi" \
> "$OUT/panel-files.txt" || true


echo "[4] Service map..."

systemctl list-units \
--type=service \
--no-pager \
2>/dev/null |
grep -Ei \
"config-location|fetch|panel" \
> "$OUT/services.txt" || true


python3 <<PY

import json,datetime


data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"phase":"25.2.1",

"fetch_files":
open("$OUT/fetch-files.txt").read().splitlines(),

"panel_files":
open("$OUT/panel-files.txt").read().splitlines(),

"services":
open("$OUT/services.txt").read().splitlines(),


"upgrade_rules":[

"modify_existing_fetcher",

"modify_existing_panel",

"no_second_core",

"config_manager_as_source"

]

}


json.dump(
data,
open(
"$OUT/fetch-panel-audit.json",
"w"
),
indent=2,
ensure_ascii=False
)

PY


cp "$OUT/fetch-panel-audit.json" \
"$REPO/dev-context/fetch-panel-integration/fetch-panel-audit.json"


echo "[GitHub Sync]"

cd "$REPO"

git add dev-context/fetch-panel-integration


git commit \
-m "Phase 25.2.1 Fetch Panel Integration Audit $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25.2.1 COMPLETE"
echo "=============================================="

