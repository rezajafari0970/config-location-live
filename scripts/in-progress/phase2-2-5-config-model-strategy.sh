#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

OUT="$DEV/config-model-strategy"

mkdir -p \
"$OUT" \
"$REPO/dev-context/config-model"


TS="$(date +%Y%m%d-%H%M%S)"


ANALYSIS="$OUT/current-model-analysis-$TS.json"
SCHEMA="$OUT/target-schema-$TS.json"
MIGRATION="$OUT/migration-strategy-$TS.json"


echo "=============================================="
echo " PHASE 2.2-2.5 CONFIG MODEL STRATEGY"
echo "=============================================="


echo "[1] Reading previous audit..."

AUDIT=$(ls -1t \
"$DEV/config-model/"*.json \
2>/dev/null | head -1 || true)


python3 <<PY

import json,datetime,os


audit_file="$AUDIT"


audit={}

if audit_file and os.path.exists(audit_file):

    try:
        audit=json.load(open(audit_file))
    except:
        pass



analysis={

"time":datetime.datetime.now().astimezone().isoformat(),

"phase":"2.2",

"current_state":{

"detected_files":
audit.get("data_candidates",[]),

"storage_candidates":
audit.get("storage_candidates",[]),

"schema_candidates":
audit.get("schema_candidates",[])

},


"required_fields":{

"raw":True,

"protocol":True,

"source":True,

"parsed":True,

"runtime":True,

"health":True,

"location":True,

"remark":True,

"lifecycle":True,

"publish":True

}

}


json.dump(
analysis,
open("$ANALYSIS","w"),
indent=2,
ensure_ascii=False
)



schema={

"version":1,

"config":{

"id":"",

"raw":{},

"protocol":"",

"source":"",

"parsed":{},

"runtime":{},

"health":{},

"location":{},

"remark":"",

"lifecycle":{},

"publish":True

}

}


json.dump(
schema,
open("$SCHEMA","w"),
indent=2,
ensure_ascii=False
)



migration={

"strategy":"non destructive",

"steps":[

"backup current store",

"create compatibility layer",

"map old fields",

"validate migrated records",

"enable new model"

],


"rollback":True

}


json.dump(
migration,
open("$MIGRATION","w"),
indent=2,
ensure_ascii=False
)

PY


echo "[2] Publish Dev Context..."

cp "$ANALYSIS" \
"$REPO/dev-context/config-model/current-model-analysis-latest.json"

cp "$SCHEMA" \
"$REPO/dev-context/config-model/target-schema-latest.json"

cp "$MIGRATION" \
"$REPO/dev-context/config-model/migration-strategy-latest.json"



echo "[3] GitHub Sync..."

cd "$REPO"

git add dev-context/config-model


git commit \
-m "Phase 2 Config Model Strategy $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " CONFIG MODEL STRATEGY COMPLETE"
echo "=============================================="

