#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CORE="/opt/config-location"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

OUT="$DEV/fetcher-integration"

mkdir -p \
"$OUT" \
"$REPO/dev-context/fetcher-integration"


echo "=============================================="
echo " PHASE 25.1 EXISTING FETCHER REAL AUDIT"
echo "=============================================="


echo "[1] Searching fetch modules..."

find "$CORE" \
-type f \
2>/dev/null \
| grep -Ei \
"fetch|collector|source|subscription|telegram|http|url" \
> /tmp/fetch-files.txt || true


echo "[2] Searching fetch services..."

systemctl list-unit-files \
--type=service \
2>/dev/null \
| grep -Ei \
"fetch|collector|config-location" \
> /tmp/fetch-services.txt || true



echo "[3] Searching fetch functions..."

python3 <<PY

import os,re,json,datetime


files=open("/tmp/fetch-files.txt").read().splitlines()


results=[]


for f in files:

    if not f.endswith(".py"):
        continue

    try:

        text=open(f,errors="ignore").read()

        funcs=re.findall(
        r'def\\s+([a-zA-Z0-9_]+)',
        text
        )


        matches=[]

        for word in [
        "fetch",
        "download",
        "source",
        "url",
        "collect"
        ]:

            if word in text.lower():
                matches.append(word)


        results.append({

        "file":f,

        "functions":funcs[:50],

        "keywords":matches

        })


    except:
        pass



data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"fetch_files":
files,

"analysis":
results,

"services":
open("/tmp/fetch-services.txt").read().splitlines()

}


json.dump(
data,
open(
"$OUT/fetcher-audit.json",
"w"
),
indent=2,
ensure_ascii=False
)

PY



echo "[4] Creating integration plan..."

cat >"$OUT/fetcher-integration-plan.json" <<JSON
{
"phase":"25.1",

"mode":"upgrade_existing_fetcher",


"changes":[

"connect_config_manager",

"connect_raw_storage",

"connect_source_manager",

"preserve_existing_behavior"

],


"forbidden":[

"new_fetch_core",

"replace_existing_fetcher"

]

}
JSON



echo "[5] Publish Context..."

cp "$OUT/fetcher-audit.json" \
"$REPO/dev-context/fetcher-integration/fetcher-audit.json"

cp "$OUT/fetcher-integration-plan.json" \
"$REPO/dev-context/fetcher-integration/fetcher-integration-plan.json"



echo "[6] GitHub Sync..."

cd "$REPO"

git add dev-context/fetcher-integration


git commit \
-m "Phase 25.1 Existing Fetcher Audit $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 25.1 AUDIT COMPLETE"
echo "=============================================="

