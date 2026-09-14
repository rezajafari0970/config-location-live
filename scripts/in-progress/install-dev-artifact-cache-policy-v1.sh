#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

CACHE="$DEV/artifact-cache"

mkdir -p \
"$CACHE/large-files" \
"$CACHE/archive"


echo "=============================================="
echo " DEV ARTIFACT CACHE POLICY v1"
echo "=============================================="


cat >"$DEV/artifact-policy.json" <<JSON
{
 "github_max_file_mb":50,
 "archive_after_days":7,
 "large_files":"google-drive-or-cache",
 "github_mode":"metadata_only"
}
JSON


echo "[1/5] Finding large files..."

find "$REPO/dev-context" \
-type f \
-size +50M \
2>/dev/null \
> /tmp/dev-large-files.txt || true


while read -r FILE
do

[ -z "$FILE" ] && continue

NAME=$(basename "$FILE")

echo "Archiving:"
echo "$FILE"

mv "$FILE" \
"$CACHE/large-files/$NAME"

done < /tmp/dev-large-files.txt


echo "[2/5] Creating artifact index..."

python3 <<PY

import os,json,datetime


root="$CACHE"

items=[]

for dp,ds,fs in os.walk(root):

    for f in fs:

        p=os.path.join(dp,f)

        items.append({

        "file":p,

        "size":os.path.getsize(p)

        })


data={

"time":datetime.datetime.now().astimezone().isoformat(),

"count":len(items),

"files":items

}


with open(
"$DEV/artifact-index.json",
"w"
) as f:

    json.dump(
    data,
    f,
    indent=2
    )

PY


echo "[3/5] Updating gitignore..."

cat >>"$REPO/.gitignore" <<EOF

# Dev large artifacts
dev-context/**/*
!dev-context/**/latest.json
!dev-context/**/summary*.json

