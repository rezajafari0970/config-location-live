#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

AUDIT_DIR="/var/lib/config-location/dev-assistant-v3/audit"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

TS="$(date +%Y%m%d-%H%M%S)"

OUT="$DEV/analysis/core-analysis-$TS.json"
TXT="$DEV/analysis/core-analysis-$TS.txt"

mkdir -p \
"$DEV/analysis" \
"$REPO/dev-context/analysis"


echo "=============================================="
echo " CONFIG LOCATION CORE ANALYSIS"
echo "=============================================="


LATEST_JSON=$(ls -1t "$AUDIT_DIR"/*.json 2>/dev/null | head -1 || true)

if [ -z "$LATEST_JSON" ]; then
    echo "ERROR: No audit file found"
    exit 1
fi


echo "[1] Reading audit..."
echo "$LATEST_JSON"


python3 <<PY

import json
import os
import datetime


src="$LATEST_JSON"

with open(src) as f:
    audit=json.load(f)


modules=audit.get("modules",[])


categories={

"fetch":[
"fetch",
"collector",
"source"
],

"storage":[
"store",
"storage",
"database",
"config"
],

"parser":[
"parser",
"decode",
"classifier"
],

"health":[
"health",
"probe",
"test"
],

"country":[
"country",
"location",
"geo"
],

"lifecycle":[
"life",
"expire",
"watchdog"
],

"panel":[
"panel",
"web",
"ui"
]

}


result={}

for name,keys in categories.items():
    found=[]
    for m in modules:
        ml=m.lower()
        if any(k in ml for k in keys):
            found.append(m)

    result[name]={
        "detected":len(found)>0,
        "modules":found
    }


analysis={

"timestamp":
datetime.datetime.now().astimezone().isoformat(),

"source_audit":
src,

"modules":
modules,

"architecture":
result,


"recommendations":{

"preserve_existing_core":True,

"avoid_second_core":True,

"next_focus":
"existing runtime and xray pipeline audit"

}

}


os.makedirs(
os.path.dirname("$OUT"),
exist_ok=True
)


with open("$OUT","w") as f:
    json.dump(
        analysis,
        f,
        indent=2,
        ensure_ascii=False
    )

PY


cat >"$TXT" <<TXT
CONFIG LOCATION CORE ANALYSIS

TIME:
$(date -Is)

SOURCE:
$LATEST_JSON


=====================
MODULE DETECTION
=====================

$(cat "$OUT")


TXT


echo "[2] Publishing Dev Context..."

cp "$OUT" \
"$REPO/dev-context/analysis/core-analysis-latest.json"

cp "$TXT" \
"$REPO/dev-context/analysis/core-analysis-latest.txt"


echo "[3] GitHub Sync..."

cd "$REPO"

git add dev-context/analysis


if git diff --cached --quiet
then
    echo "NO CHANGES"
else

git commit \
-m "Phase 1.2 Core Architecture Analysis $(date -Is)"

git push origin main

fi


echo
echo "=============================================="
echo " CORE ANALYSIS COMPLETE"
echo "=============================================="

echo
echo "REPORT:"
echo "$OUT"

