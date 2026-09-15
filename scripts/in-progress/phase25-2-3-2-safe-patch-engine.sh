#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CORE="/opt/config-location"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

BASE="$DEV/fetch-panel-patch-apply"

mkdir -p \
"$BASE/backup" \
"$BASE/result" \
"$REPO/dev-context/fetch-panel-patch-apply"


echo "=============================================="
echo " PHASE 25.2.3.2 SAFE PATCH ENGINE"
echo "=============================================="


PATCH_MAP="$DEV/fetch-panel-patch/patch-points.json"

if [ ! -f "$PATCH_MAP" ]; then
    echo "ERROR: patch map missing"
    exit 1
fi


echo "[1] Backup Core..."

tar czf \
"$BASE/backup/core-before-patch-$(date +%Y%m%d-%H%M%S).tar.gz" \
"$CORE" \
2>/dev/null || true



echo "[2] Creating Integration Layer..."

mkdir -p \
/var/lib/config-location/integration/fetch \
/var/lib/config-location/integration/panel


cat >/var/lib/config-location/integration/fetch/adapter.json <<JSON
{
"version":1,

"mode":"safe-adapter",

"features":[

"config-manager-hook",

"source-manager-hook",

"raw-storage-hook"

]

}
JSON



cat >/var/lib/config-location/integration/panel/adapter.json <<JSON
{
"version":1,

"mode":"safe-adapter",

"features":[

"source-control",

"fetch-settings",

"config-manager-binding"

]

}
JSON



echo "[3] Syntax Check Existing Python..."

python3 - <<PY

import os,py_compile,json


targets=[]

with open("$PATCH_MAP") as f:
    data=json.load(f)


for section in [
"fetch_targets",
"panel_targets"
]:

    for x in data.get(section,[]):

        f=x.get("file")

        if f and f.endswith(".py") and os.path.exists(f):

            targets.append(f)


failed=[]

for f in targets:

    try:
        py_compile.compile(
            f,
            doraise=True
        )

    except Exception as e:
        failed.append({
        "file":f,
        "error":str(e)
        })


json.dump(
{
"checked":targets,
"failed":failed
},
open(
"$BASE/result/syntax-test.json",
"w"
),
indent=2
)


if failed:
    raise SystemExit(1)

PY



echo "[4] Create Patch Report..."

python3 <<PY

import json,datetime


data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"phase":"25.2.3.2",

"mode":"adapter-only",


"core_modified":

False,


"integration_created":

True,


"status":

"ready-for-runtime-connection"

}


json.dump(
data,
open(
"$BASE/result/patch-report.json",
"w"
),
indent=2
)

PY



echo "[5] Publish Context..."

cp "$BASE/result/"*.json \
"$REPO/dev-context/fetch-panel-patch-apply/"


echo "[6] GitHub Sync..."

cd "$REPO"

git add dev-context/fetch-panel-patch-apply


git commit \
-m "Phase 25.2.3.2 Safe Patch Engine $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25.2.3.2 COMPLETE"
echo "=============================================="

