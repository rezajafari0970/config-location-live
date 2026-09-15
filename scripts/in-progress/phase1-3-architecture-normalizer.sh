#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

OUTDIR="$DEV/architecture-map"

mkdir -p "$OUTDIR" \
"$REPO/dev-context/architecture"


TS="$(date +%Y%m%d-%H%M%S)"

JSON="$OUTDIR/architecture-map-$TS.json"
TXT="$OUTDIR/architecture-map-$TS.txt"


echo "=============================================="
echo " PHASE 1.3 ARCHITECTURE NORMALIZER"
echo "=============================================="


AUDIT=$(ls -1t "$DEV/audit/"*.json 2>/dev/null | head -1 || true)

ANALYSIS="$DEV/analysis/core-analysis-latest.json"


if [ -z "$AUDIT" ]; then
    echo "ERROR: Audit not found"
    exit 1
fi


if [ ! -f "$ANALYSIS" ]; then
    echo "ERROR: Analysis not found"
    exit 1
fi


python3 <<PY

import json
import datetime


with open("$AUDIT") as f:
    audit=json.load(f)


with open("$ANALYSIS") as f:
    analysis=json.load(f)


architecture={

"timestamp":
datetime.datetime.now().astimezone().isoformat(),


"project":
"config-location",


"principles":[

"preserve_existing_core",

"no_second_core",

"zero_hardcode",

"modular_upgrade"

],


"current_state":{


"modules":
analysis.get("modules",[]),


"detected":
analysis.get("architecture",{})

},


"preserve":{

"fetcher":True,

"store":True,

"existing_services":True,

"dev_infrastructure":True

},


"development_priority":[


{
"order":1,
"component":"xray_runtime_launcher",
"reason":
"required for real health testing"
},


{
"order":2,
"component":"xray_health_engine",
"reason":
"upload/download validation"
},


{
"order":3,
"component":"location_engine",
"reason":
"country detection after health"
}


],


"avoid":{

"second_core":True,

"rewrite_existing_fetch":True

}


}


with open("$JSON","w") as f:
    json.dump(
        architecture,
        f,
        indent=2,
        ensure_ascii=False
    )


PY


cat >"$TXT" <<TXT
CONFIG LOCATION ARCHITECTURE MAP

TIME:
$(date -Is)

SOURCE AUDIT:
$AUDIT


SOURCE ANALYSIS:
$ANALYSIS


RULES:

- Preserve current core
- No second core
- Upgrade existing modules only
- Zero hard-code


NEXT DEVELOPMENT PRIORITY:

1. Xray Runtime Launcher
2. Real Upload/Download Health
3. Location Intelligence

TXT


cp "$JSON" \
"$REPO/dev-context/architecture/architecture-map-latest.json"

cp "$TXT" \
"$REPO/dev-context/architecture/architecture-map-latest.txt"


echo "[GitHub Sync]"

cd "$REPO"

git add dev-context/architecture


if git diff --cached --quiet
then
    echo "NO CHANGES"
else

git commit \
-m "Phase 1.3 Architecture Map $(date -Is)"

git push origin main

fi


echo
echo "=============================================="
echo " PHASE 1.3 COMPLETE"
echo "=============================================="

echo "REPORT:"
echo "$JSON"

