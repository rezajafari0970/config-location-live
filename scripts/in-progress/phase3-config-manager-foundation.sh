#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/config-manager"
DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"


mkdir -p \
"$BASE/versions" \
"$BASE/migrations" \
"$REPO/dev-context/config-manager"


echo "=============================================="
echo " PHASE 3 CONFIG MANAGER FOUNDATION"
echo "=============================================="


cat >"$BASE/config.json" <<JSON
{
 "version":1,

 "system":{
   "mode":"auto"
 },

 "workers":{
   "mode":"auto",
   "max_workers":"auto"
 },

 "health":{
   "interval":"auto",
   "download":true,
   "upload":true,
   "timeout":"auto"
 },

 "runtime":{
   "startup_timeout":"auto",
   "cleanup_timeout":"auto"
 },

 "lifecycle":{
   "ttl":"48h"
 }
}
JSON


cat >"$BASE/schema.json" <<JSON
{
"version":1,

"required":[

"system",

"workers",

"health",

"runtime",

"lifecycle"

]

}
JSON


cat >"$BASE/migrations/README.md" <<EOF2
# Config Manager Migrations

All future configuration changes
must be migrated here.
EOF2


cat >/usr/local/bin/config-manager-get <<'SCRIPT'
#!/usr/bin/env bash
set -e

cat /var/lib/config-location/config-manager/config.json

SCRIPT


chmod 700 /usr/local/bin/config-manager-get


cat >/usr/local/bin/config-manager-validate <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

python3 <<PY

import json

cfg=json.load(
open("/var/lib/config-location/config-manager/config.json")
)

schema=json.load(
open("/var/lib/config-location/config-manager/schema.json")
)

missing=[]

for x in schema["required"]:
    if x not in cfg:
        missing.append(x)

if missing:
    print("INVALID")
    print(missing)
    exit(1)

print("VALID")

PY

SCRIPT


chmod 700 /usr/local/bin/config-manager-validate


echo "[1] Validate..."

config-manager-validate


echo "[2] Create Dev Context..."


python3 <<PY

import json,datetime

data={

"time":datetime.datetime.now().astimezone().isoformat(),

"path":"/var/lib/config-location/config-manager",

"version":1,

"features":[

"central-config",

"dynamic-settings",

"migration-ready"

]

}


json.dump(
data,
open("$REPO/dev-context/config-manager/config-manager-state.json","w"),
indent=2
)

PY


echo "[3] GitHub Sync..."

cd "$REPO"

git add dev-context/config-manager


git commit \
-m "Phase 3 Config Manager Foundation $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 3 COMPLETE"
echo "=============================================="

