#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

OUT="$DEV/core-map"

mkdir -p \
"$OUT" \
"$REPO/dev-context/core-map"


TS="$(date +%Y%m%d-%H%M%S)"


DEP_JSON="$OUT/dependency-map-$TS.json"
FLOW_JSON="$OUT/data-flow-$TS.json"
STAB_JSON="$OUT/stability-report-$TS.json"


echo "=============================================="
echo " PHASE 1.4 1.5 1.6 CORE INTELLIGENCE MAP"
echo "=============================================="


echo "[1] Collect services"


systemctl list-units \
--type=service \
--no-legend \
2>/dev/null |
grep -Ei \
"config-location|health|country|fetch|lifecycle|panel|xray" \
> /tmp/core-services.txt || true



echo "[2] Collect python modules"


find /opt/config-location \
-type f \
-name "*.py" \
2>/dev/null \
> /tmp/core-python-files.txt || true



echo "[3] Analyze imports"


python3 <<PY

import os,json,re,datetime


files=open("/tmp/core-python-files.txt").read().splitlines()


modules=[]

for f in files:

    try:
        text=open(f,errors="ignore").read()

        imports=re.findall(
        r'^(?:from|import)\\s+([a-zA-Z0-9_\\.]+)',
        text,
        re.M
        )

        modules.append({

        "file":f,

        "imports":imports[:100]

        })

    except:
        pass



data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"python_files":
len(files),

"modules":
modules,

"services":
open("/tmp/core-services.txt").read().splitlines()

}



json.dump(
data,
open("$DEP_JSON","w"),
indent=2,
ensure_ascii=False
)


PY



echo "[4] Create data flow map"


python3 <<PY

import json,datetime


flow={

"time":
datetime.datetime.now().astimezone().isoformat(),


"pipeline":[

{
"stage":"source",
"next":"fetch"
},

{
"stage":"fetch",
"next":"store"
},

{
"stage":"store",
"next":"classifier"
},

{
"stage":"classifier",
"next":"parser"
},

{
"stage":"parser",
"next":"runtime"
},

{
"stage":"runtime",
"next":"health"
},

{
"stage":"health",
"next":"country"
},

{
"stage":"country",
"next":"publish"
}

]

}


json.dump(
flow,
open("$FLOW_JSON","w"),
indent=2
)


PY



echo "[5] Stability analysis"


python3 <<PY

import json,datetime,subprocess,os


def run(c):

    try:
        return subprocess.check_output(
        c,
        shell=True,
        text=True,
        stderr=subprocess.STDOUT
        )[:5000]

    except Exception as e:
        return str(e)



data={

"time":
datetime.datetime.now().astimezone().isoformat(),


"services":
run(
"cat /tmp/core-services.txt"
),


"recent_errors":
run(
"journalctl --since '1 hour ago' --no-pager | grep -Ei 'error|fail|exception' | tail -50"
),


"disk":
run(
"df -h /opt/config-location"
),


"recommendation":

[
"preserve existing core",
"audit before modification",
"upgrade by migration"
]

}


json.dump(
data,
open("$STAB_JSON","w"),
indent=2
)

PY



echo "[6] Publish Context"


cp "$DEP_JSON" \
"$REPO/dev-context/core-map/dependency-map-latest.json"

cp "$FLOW_JSON" \
"$REPO/dev-context/core-map/data-flow-latest.json"

cp "$STAB_JSON" \
"$REPO/dev-context/core-map/stability-report-latest.json"



cd "$REPO"

git add dev-context/core-map


git commit \
-m "Phase 1.4-1.6 Core Intelligence Map $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " CORE MAP COMPLETE"
echo "=============================================="

