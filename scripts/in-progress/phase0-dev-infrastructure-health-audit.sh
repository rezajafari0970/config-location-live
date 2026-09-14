#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEV="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

OUT="$DEV/health"

mkdir -p \
"$OUT" \
"$REPO/dev-context/health"

TS="$(date +%Y%m%d-%H%M%S)"

JSON="$OUT/dev-infrastructure-health-$TS.json"
TXT="$OUT/dev-infrastructure-health-$TS.txt"


echo "=============================================="
echo " PHASE 0 DEV INFRASTRUCTURE HEALTH AUDIT"
echo "=============================================="


python3 <<PY

import os
import json
import datetime
import subprocess


def exists(path):
    return os.path.exists(path)


def cmd(c):
    try:
        return subprocess.check_output(
            c,
            shell=True,
            stderr=subprocess.STDOUT,
            text=True
        ).strip()
    except Exception as e:
        return str(e)


result={

"time":
datetime.datetime.now().astimezone().isoformat(),

"checks":{

"dev_context":
exists("$DEV"),

"executions":
exists("$DEV/executions"),

"errors":
exists("$DEV/errors"),

"changes":
exists("$DEV/changes"),

"snapshots":
exists("$DEV/snapshots"),

"artifact_policy":
exists("$DEV/artifact-policy.json"),

"git_repo":
exists("$REPO/.git"),

"dev_exec":
exists("/usr/local/bin/dev-exec")

},


"git":{

"branch":
cmd("git -C $REPO branch --show-current"),

"commit":
cmd("git -C $REPO rev-parse HEAD"),

"status":
cmd("git -C $REPO status --short")

},


"latest_files":[]

}


for root,dirs,files in os.walk("$DEV"):

    for f in files:

        if "latest" in f:

            result["latest_files"].append(
                os.path.join(root,f)
            )


with open("$JSON","w") as f:
    json.dump(
        result,
        f,
        indent=2,
        ensure_ascii=False
    )

PY


cat >"$TXT" <<TXT
PHASE 0 DEV INFRASTRUCTURE HEALTH AUDIT

TIME:
$(date -Is)


DEV CONTEXT:
$(test -d "$DEV" && echo OK || echo FAIL)


GITHUB:
$(test -d "$REPO/.git" && echo OK || echo FAIL)


DEV EXEC:
$(test -f /usr/local/bin/dev-exec && echo OK || echo FAIL)


LATEST CONTEXT FILES:

$(find "$DEV" -name "*latest*" -type f 2>/dev/null)


GIT:

$(git -C "$REPO" status --short 2>/dev/null || true)

TXT


cp "$JSON" \
"$REPO/dev-context/health/dev-infrastructure-health-latest.json"

cp "$TXT" \
"$REPO/dev-context/health/dev-infrastructure-health-latest.txt"


echo "[GitHub Sync]"

cd "$REPO"

git add dev-context/health


git commit \
-m "Phase 0 Dev Infrastructure Health Audit $(date -Is)" \
|| true


git push origin main


echo
echo "=============================================="
echo " PHASE 0 HEALTH AUDIT COMPLETE"
echo "=============================================="

echo "$JSON"

