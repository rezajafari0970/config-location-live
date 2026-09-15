#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

BASE="$DEV/core-integration-plan"

mkdir -p \
"$BASE" \
"$REPO/dev-context/core-integration"


echo "=============================================="
echo " PHASE 21.2 - 21.8 CORE INTEGRATION PLAN"
echo "=============================================="


cat >"$BASE/integration-decision.json" <<JSON
{
"mode":"upgrade_existing_core",

"rules":[
"no_second_core",
"preserve_existing_services",
"migration_only",
"rollback_required"
],

"status":"planning_complete"
}
JSON


cat >"$BASE/protected-files.json" <<JSON
{
"protected": [

"existing_fetch_core",
"existing_store",
"existing_panel",
"existing_services"

],

"rule":"modify_only_after_audit"
}
JSON


cat >"$BASE/config-model-plan.json" <<JSON
{
"phase":"21.3",

"goal":"connect unified config model",

"actions":[

"audit current records",

"add compatibility layer",

"migrate gradually",

"validate records"

],

"risk":"medium"
}
JSON


cat >"$BASE/fetch-plan.json" <<JSON
{
"phase":"21.4",

"goal":"upgrade existing fetcher",

"actions":[

"connect config manager",

"add queue integration",

"add resource awareness",

"preserve sources"

],

"risk":"low"
}
JSON


cat >"$BASE/parser-plan.json" <<JSON
{
"phase":"21.5",

"goal":"upgrade existing xray parser",

"protocols":[

"vless",
"vmess",
"trojan",
"ss",
"xray_json",
"custom_json"

],

"risk":"high"
}
JSON


cat >"$BASE/runtime-plan.json" <<JSON
{
"phase":"21.6",

"goal":"connect runtime launcher",

"actions":[

"sandbox",
"xray process control",
"cleanup",
"isolation"

],

"risk":"high"
}
JSON


cat >"$BASE/health-plan.json" <<JSON
{
"phase":"21.7",

"goal":"connect real traffic health",

"tests":[

"download",
"upload",
"latency",
"stability"

],

"risk":"high"
}
JSON


cat >"$BASE/panel-plan.json" <<JSON
{
"phase":"21.8",

"goal":"connect panel to config manager",

"modules":[

"health",
"workers",
"lifecycle",
"publish"

],

"risk":"medium"
}
JSON


cat >"$BASE/risk-report.json" <<JSON
{
"overall":"controlled",

"high_risk":[

"parser",
"runtime",
"health"

],

"strategy":[

"snapshot_before_change",
"one_module_at_time",
"test_after_upgrade"

]
}
JSON



echo "[Publish Dev Context]"


cp "$BASE/"*.json \
"$REPO/dev-context/core-integration/"


echo "[GitHub Sync]"

cd "$REPO"

git add dev-context/core-integration


git commit \
-m "Phase 21.2-21.8 Core Integration Planning $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 21.2 - 21.8 COMPLETE"
echo "=============================================="

