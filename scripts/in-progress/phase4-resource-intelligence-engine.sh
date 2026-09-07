#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/resource-intelligence"
CONFIG="/var/lib/config-location/config-manager/config.json"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE" \
"$REPO/dev-context/resource-intelligence"


echo "=============================================="
echo " PHASE 4 RESOURCE INTELLIGENCE ENGINE"
echo "=============================================="


cat >/usr/local/bin/resource-intelligence-scan <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/lib/config-location/resource-intelligence"
CONFIG="/var/lib/config-location/config-manager/config.json"


python3 <<PY

import json
import os
import datetime
import subprocess


def run(cmd):
    try:
        return subprocess.check_output(
            cmd,
            shell=True,
            text=True
        ).strip()
    except:
        return ""


cpu=os.cpu_count() or 1


mem=os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES')


load=run("cat /proc/loadavg")


disk=run("df -h / | tail -1")


profile="small"

if cpu>=8 and mem>16*1024**3:
    profile="large"
elif cpu>=4 and mem>8*1024**3:
    profile="medium"


if profile=="small":
    workers={
        "fetch":4,
        "parser":4,
        "health":8
    }

elif profile=="medium":
    workers={
        "fetch":10,
        "parser":20,
        "health":40
    }

else:
    workers={
        "fetch":30,
        "parser":60,
        "health":120
    }


data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"profile":profile,

"cpu":cpu,

"memory_bytes":mem,

"load":load,

"disk":disk,

"workers":workers

}


json.dump(
data,
open("$BASE/resource-profile.json","w"),
indent=2,
ensure_ascii=False
)


PY


SCRIPT


chmod 700 /usr/local/bin/resource-intelligence-scan


echo "[1] Running discovery..."

resource-intelligence-scan


echo "[2] Updating Dev Context..."

cp \
"$BASE/resource-profile.json" \
"$REPO/dev-context/resource-intelligence/resource-profile.json"


echo "[3] GitHub Sync..."

cd "$REPO"

git add dev-context/resource-intelligence


git commit \
-m "Phase 4 Resource Intelligence $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 4 COMPLETE"
echo "=============================================="

