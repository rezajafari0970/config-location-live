#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

OUTDIR="$DEV/config-model"

mkdir -p \
"$OUTDIR" \
"$REPO/dev-context/config-model"


TS="$(date +%Y%m%d-%H%M%S)"

JSON="$OUTDIR/config-model-audit-$TS.json"
TXT="$OUTDIR/config-model-audit-$TS.txt"


echo "=============================================="
echo " PHASE 2.1 CONFIG DATA MODEL AUDIT"
echo "=============================================="


echo "[1] Searching storage locations..."

find /opt/config-location \
/var/lib/config-location \
-type f \
2>/dev/null \
| grep -Ei \
"config|store|db|json|sqlite|yaml|yaml|state|record|queue" \
> /tmp/config-model-files.txt || true


echo "[2] Searching schemas..."

find /opt/config-location \
-type f \
2>/dev/null \
| grep -Ei \
"schema|model|store|database|storage|config" \
> /tmp/config-model-schema-files.txt || true


echo "[3] Detecting config examples..."

find /opt/config-location \
/var/lib/config-location \
-type f \
2>/dev/null \
| grep -Ei \
"\.json$|\.jsonl$|\.db$|\.sqlite$" \
| head -200 \
> /tmp/config-model-data-files.txt || true


echo "[4] Collecting samples..."

python3 <<PY

import os
import json
import datetime


def read_sample(path):
    result={}

    try:
        size=os.path.getsize(path)
        result["size"]=size

        if path.endswith(".json") or path.endswith(".jsonl"):
            with open(path,errors="ignore") as f:
                data=f.read(2000)

            result["sample"]=data[:1000]

    except Exception as e:
        result["error"]=str(e)

    return result



files=open("/tmp/config-model-data-files.txt").read().splitlines()

samples={}

for f in files[:50]:
    samples[f]=read_sample(f)


audit={

"timestamp":
datetime.datetime.now().astimezone().isoformat(),

"project":
"config-location",


"storage_candidates":
open("/tmp/config-model-files.txt").read().splitlines()[:500],


"schema_candidates":
open("/tmp/config-model-schema-files.txt").read().splitlines()[:200],


"data_candidates":
files,


"samples":
samples,


"expected_model_fields":[

"raw",

"type",

"source",

"parsed",

"runtime",

"health",

"location",

"remark",

"lifecycle",

"publish"

]

}


with open("$JSON","w") as f:
    json.dump(
        audit,
        f,
        indent=2,
        ensure_ascii=False
    )


PY


cat >"$TXT" <<TXT
CONFIG DATA MODEL AUDIT

TIME:
$(date -Is)


STORAGE CANDIDATES:
$(cat /tmp/config-model-files.txt)


SCHEMA CANDIDATES:
$(cat /tmp/config-model-schema-files.txt)


DATA FILES:
$(cat /tmp/config-model-data-files.txt)


TXT


echo "[5] Publishing Dev Context..."

cp "$JSON" \
"$REPO/dev-context/config-model/config-model-audit-latest.json"

cp "$TXT" \
"$REPO/dev-context/config-model/config-model-audit-latest.txt"


echo "[6] GitHub Sync..."

cd "$REPO"

git add dev-context/config-model


if git diff --cached --quiet
then
    echo "NO CHANGES"
else

git commit \
-m "Phase 2.1 Config Data Model Audit $(date -Is)"

git push origin main

fi


echo
echo "=============================================="
echo " PHASE 2.1 COMPLETE"
echo "=============================================="

echo "REPORT:"
echo "$JSON"

