#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CORE="/opt/config-location"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

OUT="$DEV/fetch-panel-patch"

mkdir -p \
"$OUT" \
"$REPO/dev-context/fetch-panel-patch"


echo "=============================================="
echo " PHASE 25.2.3.1 PATCH POINT RESOLVER"
echo "=============================================="


echo "[1] Loading previous audit..."

AUDIT="$DEV/fetch-panel-integration/fetch-panel-audit.json"

if [ ! -f "$AUDIT" ]; then
    echo "ERROR: Previous audit not found"
    exit 1
fi


echo "[2] Searching fetch targets..."

find "$CORE" \
-type f \
2>/dev/null |
grep -Ei \
"fetch|collector|source|subscription|worker" \
> "$OUT/fetch-files.txt" || true


echo "[3] Searching panel targets..."

find "$CORE" \
-type f \
2>/dev/null |
grep -Ei \
"panel|web|api|route|template|html|flask|fastapi|django" \
> "$OUT/panel-files.txt" || true


echo "[4] Analyzing patch points..."


python3 <<PY

import json
import re
import datetime


def analyze(files):

    result=[]

    for f in open(files).read().splitlines():

        item={
        "file":f,
        "functions":[],
        "keywords":[]
        }

        if f.endswith(".py"):

            try:

                text=open(f,errors="ignore").read()

                item["functions"]=re.findall(
                    r'def\\s+([a-zA-Z0-9_]+)',
                    text
                )[:100]


                for k in [
                    "fetch",
                    "source",
                    "url",
                    "request",
                    "download",
                    "route",
                    "api"
                ]:
                    if k in text.lower():
                        item["keywords"].append(k)

            except:
                pass


        result.append(item)

    return result



data={

"time":
datetime.datetime.now().astimezone().isoformat(),


"fetch_targets":
analyze("$OUT/fetch-files.txt"),


"panel_targets":
analyze("$OUT/panel-files.txt")

}


json.dump(
data,
open(
"$OUT/patch-points.json",
"w"
),
indent=2,
ensure_ascii=False
)

PY



echo "[5] Creating Risk Report..."

cat >"$OUT/dependency-risk.json" <<JSON
{
"risk":"controlled",

"rules":[

"do_not_modify_without_target",

"backup_before_patch",

"test_after_patch"

],

"protected":

"/opt/config-location"

}
JSON



cat >"$OUT/next-action.json" <<JSON
{
"next":

"phase25.2.3.2",

"action":

"apply_safe_patch_after_review",

"mode":

"existing_core_only"

}
JSON



echo "[6] Publish Context..."

cp "$OUT/patch-points.json" \
"$REPO/dev-context/fetch-panel-patch/patch-points.json"

cp "$OUT/dependency-risk.json" \
"$REPO/dev-context/fetch-panel-patch/dependency-risk.json"

cp "$OUT/next-action.json" \
"$REPO/dev-context/fetch-panel-patch/next-action.json"



echo "[7] GitHub Sync..."

cd "$REPO"

git add dev-context/fetch-panel-patch


git commit \
-m "Phase 25.2.3.1 Patch Point Resolver $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25.2.3.1 COMPLETE"
echo "=============================================="

