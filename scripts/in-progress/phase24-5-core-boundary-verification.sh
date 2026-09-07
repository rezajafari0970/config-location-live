#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CORE="/opt/config-location"
LAYERS="/var/lib/config-location"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

OUT="$DEV/core-boundary"

mkdir -p \
"$OUT" \
"$REPO/dev-context/core-boundary"


echo "=============================================="
echo " PHASE 24.5 CORE BOUNDARY VERIFICATION"
echo "=============================================="


python3 <<PY

import os,json,datetime


def scan(path):

    result=[]

    if os.path.exists(path):

        for root,dirs,files in os.walk(path):

            for f in files[:]:

                result.append(
                    os.path.join(root,f)
                )

    return result[:1000]


data={

"time":
datetime.datetime.now().astimezone().isoformat(),


"core":{

"path":"$CORE",

"files":scan("$CORE")

},


"integration_layers":{

"path":"$LAYERS",

"files":scan("$LAYERS")

},


"rules":{

"modify_core_only":True,

"no_second_core":True,

"layers_are_adapters":True

},


"next_action":

"integrate existing core modules"

}


json.dump(
data,
open(
"$OUT/core-boundary-report.json",
"w"
),
indent=2,
ensure_ascii=False
)

PY


cp "$OUT/core-boundary-report.json" \
"$REPO/dev-context/core-boundary/core-boundary-report.json"


cd "$REPO"

git add dev-context/core-boundary


git commit \
-m "Phase 24.5 Core Boundary Verification $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 24.5 COMPLETE"
echo "=============================================="

