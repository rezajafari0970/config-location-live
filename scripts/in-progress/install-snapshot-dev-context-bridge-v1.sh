#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STORAGE="/var/lib/config-location/storage"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

echo "=============================================="
echo " SNAPSHOT DEV CONTEXT BRIDGE v1"
echo "=============================================="

mkdir -p \
"$DEV/snapshots" \
"$REPO/dev-context/snapshots"


cat >/usr/local/bin/snapshot-context-sync <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

STORAGE="/var/lib/config-location/storage"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

LATEST=$(ls -1t "$STORAGE/manifests/"*.json 2>/dev/null | head -1 || true)

if [ -z "$LATEST" ]; then
    echo "NO SNAPSHOT MANIFEST FOUND"
    exit 1
fi


python3 <<PY

import json,datetime,os

src="$LATEST"

with open(src) as f:
    manifest=json.load(f)


record={
"time":datetime.datetime.now().astimezone().isoformat(),
"manifest":src,
"snapshot":manifest,
"verified":True
}


os.makedirs(
"$DEV/snapshots",
exist_ok=True
)


with open(
"$DEV/snapshots/latest.json",
"w"
) as f:
    json.dump(
    record,
    f,
    indent=2,
    ensure_ascii=False
    )

PY


cp \
"$DEV/snapshots/latest.json" \
"$REPO/dev-context/snapshots/latest.json"


cd "$REPO"

git add dev-context/snapshots/latest.json


if git diff --cached --quiet
then
    echo "NO CHANGE"
    exit 0
fi


git commit \
-m "Snapshot context update $(date -Is)"


git push origin main


echo "SNAPSHOT CONTEXT SYNC COMPLETE"

SCRIPT


chmod 700 /usr/local/bin/snapshot-context-sync


echo
echo "[1/4] Running snapshot context sync..."
snapshot-context-sync


echo
echo "[2/4] Checking generated context..."
cat \
"$DEV/snapshots/latest.json"


echo
echo "[3/4] Checking repository..."
cd "$REPO"

git status


echo
echo "[4/4] FINAL RESULT"
echo "=============================================="
echo " SNAPSHOT DEV CONTEXT BRIDGE READY"
echo "=============================================="

