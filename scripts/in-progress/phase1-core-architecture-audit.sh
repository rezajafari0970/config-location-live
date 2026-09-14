#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPORT_BASE="/var/lib/config-location/dev-assistant-v3/audit"
REPO="/var/lib/config-location/devlog-github/repo"

TS="$(date +%Y%m%d-%H%M%S)"

mkdir -p \
"$REPORT_BASE" \
"$REPO/dev-context/audit"


JSON="$REPORT_BASE/core-architecture-audit-$TS.json"
TXT="$REPORT_BASE/core-architecture-audit-$TS.txt"


echo "=============================================="
echo " CONFIG LOCATION CORE ARCHITECTURE AUDIT"
echo "=============================================="


echo "[1] Collect project files..."

find /opt/config-location \
-type f \
2>/dev/null \
| sort \
> /tmp/config-location-files.txt


echo "[2] Collect services..."

systemctl list-units \
--type=service \
--no-legend \
2>/dev/null \
| grep -Ei \
"config-location|health|country|fetch|lifecycle|panel|xray" \
> /tmp/config-location-services.txt || true


echo "[3] Collect ports..."

ss -lntp \
> /tmp/config-location-ports.txt 2>/dev/null || true


echo "[4] Collect processes..."

ps aux \
| grep -Ei \
"config-location|xray|python" \
| grep -v grep \
> /tmp/config-location-processes.txt || true


echo "[5] Collect modules..."

python3 <<PY

import os,json,datetime

root="/opt/config-location"

modules=[]

if os.path.isdir(root):
    for x in sorted(os.listdir(root)):
        p=os.path.join(root,x)
        if os.path.isdir(p):
            modules.append(x)


def read(path):
    try:
        return open(path).read()
    except:
        return ""


data={

"timestamp":datetime.datetime.now().astimezone().isoformat(),

"project":{
"name":"config-location",
"root":root
},

"modules":modules,


"files_count":
len(open("/tmp/config-location-files.txt").read().splitlines()),


"files":
open("/tmp/config-location-files.txt").read().splitlines()[:500],


"services":
read("/tmp/config-location-services.txt"),


"ports":
read("/tmp/config-location-ports.txt"),


"processes":
read("/tmp/config-location-processes.txt"),


"targets":{

"fetch":os.path.exists(root),

"health":
"health" in str(modules).lower(),

"country":
"country" in str(modules).lower(),

"panel":
"panel" in str(modules).lower()

}

}


json.dump(
data,
open("$JSON","w"),
indent=2,
ensure_ascii=False
)

PY


cat >"$TXT" <<TXT
CONFIG LOCATION CORE ARCHITECTURE AUDIT

Time:
$(date -Is)

Files:
$(wc -l </tmp/config-location-files.txt)


====================
MODULES
====================

$(ls -la /opt/config-location)


====================
SERVICES
====================

$(cat /tmp/config-location-services.txt)


====================
PORTS
====================

$(cat /tmp/config-location-ports.txt)


====================
PROCESSES
====================

$(cat /tmp/config-location-processes.txt)

TXT


echo "[6] Copy to Dev Context..."

cp "$JSON" \
"$REPO/dev-context/audit/core-architecture-audit.json"

cp "$TXT" \
"$REPO/dev-context/audit/core-architecture-audit.txt"


echo "[7] GitHub Sync..."

cd "$REPO"

git add dev-context/audit


if git diff --cached --quiet
then
    echo "NO CHANGES"
else

git commit \
-m "Phase 1.1 Core Architecture Audit $(date -Is)"

git push origin main

fi


echo
echo "=============================================="
echo " AUDIT COMPLETE"
echo "=============================================="

echo
echo "JSON:"
echo "$JSON"

echo
echo "TXT:"
echo "$TXT"

