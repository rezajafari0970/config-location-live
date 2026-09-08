#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="/var/lib/config-location/devlog-github/repo"
DEV="/var/lib/config-location/dev-assistant-v3"

SRC="$DEV/config-model"

echo "=============================================="
echo " PHASE 2.1 ARTIFACT SIZE FIX"
echo "=============================================="


mkdir -p \
"$SRC/archive" \
"$REPO/dev-context/config-model"


echo "[1/6] Checking large files..."

find "$REPO/dev-context/config-model" \
-type f \
-size +90M \
-print \
> /tmp/large-github-files.txt || true


cat /tmp/large-github-files.txt || true


echo "[2/6] Moving large artifacts out of GitHub..."


while read -r FILE
do
    [ -z "$FILE" ] && continue

    NAME=$(basename "$FILE")

    mv "$FILE" \
    "$SRC/archive/$NAME"

    echo "Moved:"
    echo "$NAME"

done < /tmp/large-github-files.txt


echo "[3/6] Creating compact summary..."

python3 <<PY

import json
import os
import datetime


src="$SRC"


data={

"time":datetime.datetime.now().astimezone().isoformat(),

"project":"config-location",

"phase":"2.1",

"artifact_policy":{

"github":"metadata_only",

"large_files":"external_storage"

},


"files":[]

}


for root,dirs,files in os.walk(src):

    for f in files:

        p=os.path.join(root,f)

        try:
            size=os.path.getsize(p)

            data["files"].append({

            "name":f,

            "path":p,

            "size":size

            })

        except:
            pass


with open(
"$REPO/dev-context/config-model/config-model-artifact-summary.json",
"w"
) as f:

    json.dump(
    data,
    f,
    indent=2,
    ensure_ascii=False
    )

PY


echo "[4/6] Removing oversized Git tracking..."

cd "$REPO"


git rm -r \
--cached \
dev-context/config-model \
2>/dev/null || true


git add \
dev-context/config-model/config-model-artifact-summary.json


echo "[5/6] Commit repair..."

git commit \
-m "Fix artifact size policy for config model audit $(date -Is)" \
|| echo "Nothing to commit"


echo "[6/6] Push..."

git push origin main


echo
echo "=============================================="
echo " ARTIFACT FIX COMPLETE"
echo "=============================================="

echo
echo "Git status:"

git status

echo
echo "Tracked config-model files:"

git ls-files dev-context/config-model

