#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT="/opt/config-location"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

OUT="$DEV/core-integration"

mkdir -p \
"$OUT" \
"$REPO/dev-context/core-integration"

TS="$(date +%Y%m%d-%H%M%S)"

FILES="$OUT/core-files-map-$TS.json"
SERVICES="$OUT/services-map-$TS.json"
DEPS="$OUT/dependency-map-$TS.json"
PLAN="$OUT/integration-plan-$TS.json"


echo "=============================================="
echo " PHASE 21.1 CORE INTEGRATION AUDIT"
echo "=============================================="


echo "[1] Scanning project files..."

find "$PROJECT" \
-type f \
2>/dev/null \
| sort \
> /tmp/core-files.txt


echo "[2] Finding services..."

systemctl list-unit-files \
--type=service \
--no-legend \
2>/dev/null \
| grep -Ei \
"config-location|health|fetch|country|panel|lifecycle|xray" \
> /tmp/core-services.txt || true



echo "[3] Mapping modules..."

python3 <<PY

import os,json,datetime,re


files=open("/tmp/core-files.txt").read().splitlines()


keywords={

"fetch":[
"fetch",
"source",
"collector"
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

"store":[
"store",
"storage",
"database"
],

"runtime":[
"runtime",
"xray"
],

"panel":[
"panel",
"web",
"api"
],

"lifecycle":[
"lifecycle",
"expire",
"ttl"
]

}


mapping={x:[] for x in keywords}


for f in files:

    low=f.lower()

    for k,words in keywords.items():

        if any(w in low for w in words):
            mapping[k].append(f)



data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"project":
"$PROJECT",

"file_count":
len(files),

"mapping":
mapping

}


json.dump(
data,
open("$FILES","w"),
indent=2,
ensure_ascii=False
)

PY



echo "[4] Dependency map..."

python3 <<PY

import os,json,re,datetime


result=[]


for f in open("/tmp/core-files.txt").read().splitlines():

    if f.endswith(".py"):

        try:

            text=open(f,errors="ignore").read()

            imports=re.findall(
            r'^(?:import|from)\\s+([a-zA-Z0-9_\\.]+)',
            text,
            re.M
            )

            result.append({

            "file":f,

            "imports":imports[:50]

            })

        except:
            pass



json.dump(

{

"time":datetime.datetime.now().astimezone().isoformat(),

"dependencies":result

},

open("$DEPS","w"),

indent=2

)

PY



echo "[5] Service map..."

python3 <<PY

import json,datetime


data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"services":
open("/tmp/core-services.txt").read().splitlines()

}


json.dump(
data,
open("$SERVICES","w"),
indent=2
)

PY



echo "[6] Integration plan..."

python3 <<PY

import json,datetime


plan={

"time":
datetime.datetime.now().astimezone().isoformat(),

"rules":[

"preserve_existing_core",

"modify_existing_modules",

"no_second_core"

],


"priority":[

"config-model-integration",

"fetch-integration",

"parser-integration",

"runtime-integration",

"health-integration",

"panel-integration"

]

}


json.dump(
plan,
open("$PLAN","w"),
indent=2
)

PY



echo "[7] Publish Context..."

cp "$FILES" \
"$REPO/dev-context/core-integration/core-files-map-latest.json"

cp "$SERVICES" \
"$REPO/dev-context/core-integration/services-map-latest.json"

cp "$DEPS" \
"$REPO/dev-context/core-integration/dependency-map-latest.json"

cp "$PLAN" \
"$REPO/dev-context/core-integration/integration-plan-latest.json"



echo "[8] GitHub Sync..."

cd "$REPO"

git add dev-context/core-integration


git commit \
-m "Phase 21.1 Existing Core Integration Audit $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 21.1 COMPLETE"
echo "=============================================="

