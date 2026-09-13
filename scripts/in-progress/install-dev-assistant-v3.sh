#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

echo "=========================================="
echo " DEV ASSISTANT v3 INSTALL"
echo "=========================================="


if [ ! -d "$REPO/.git" ]; then
    echo "[ERROR] Git repo not found:"
    echo "$REPO"
    exit 1
fi


mkdir -p \
"$BASE" \
"$BASE/runtime" \
"$BASE/errors" \
"$BASE/services" \
"$BASE/tests" \
"$BASE/executions" \
"$REPO/dev-context/runtime" \
"$REPO/dev-context/errors" \
"$REPO/dev-context/services" \
"$REPO/dev-context/tests" \
"$REPO/dev-context/executions"


cat >/usr/local/bin/dev-context-build <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/lib/config-location/dev-assistant-v3"

mkdir -p "$BASE"


echo "[1] Project map"

python3 <<'PY'
import json,os

root="/opt/config-location"

mods=[]

if os.path.isdir(root):
    for x in os.listdir(root):
        if os.path.isdir(root+"/"+x):
            mods.append(x)

data={
"project":"config-location",
"root":root,
"modules":mods
}

open(
"/var/lib/config-location/dev-assistant-v3/project-map.json",
"w"
).write(json.dumps(data,indent=2))
PY


echo "[2] Code index"

python3 <<'PY'
import os,json,hashlib

root="/opt/config-location"
out=[]

for dp,_,fs in os.walk(root):
    for f in fs:
        if f.endswith((".py",".sh",".php",".service")):
            p=os.path.join(dp,f)
            try:
                h=hashlib.sha256(open(p,"rb").read()).hexdigest()
                s=os.path.getsize(p)
                m=os.path.getmtime(p)

                out.append({
                "path":p,
                "size":s,
                "mtime":m,
                "sha256":h
                })
            except:
                pass

open(
"/var/lib/config-location/dev-assistant-v3/code-index.json",
"w"
).write(json.dumps(out,indent=2))

PY


echo "[3] Runtime"


systemctl list-units \
--type=service \
--no-legend |
grep -Ei \
"config-location|health|country|fetch|lifecycle|panel" \
> "$BASE/services/services.txt" || true


ss -lntp > "$BASE/runtime/ports.txt" || true


python3 <<PY
import json,datetime

data={
"time":datetime.datetime.now().astimezone().isoformat(),
"services":open("$BASE/services/services.txt").read(),
"ports":open("$BASE/runtime/ports.txt").read()
}

open("$BASE/runtime/latest.json","w").write(
json.dumps(data,indent=2)
)
PY


echo "[4] Errors"

journalctl \
--since "1 hour ago" \
--no-pager |
grep -Ei \
"error|failed|exception|traceback|runtime" |
tail -100 \
> "$BASE/errors/errors.txt" || true


python3 <<PY

import json,datetime

data={
"time":datetime.datetime.now().astimezone().isoformat(),
"errors":open("$BASE/errors/errors.txt").read()
}

open("$BASE/errors/latest.json","w").write(
json.dumps(data,indent=2)
)

PY


echo "BUILD COMPLETE"

SCRIPT


chmod 700 /usr/local/bin/dev-context-build


cat >/usr/local/bin/dev-context-sync <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"


dev-context-build


mkdir -p "$REPO/dev-context"


cp "$BASE/project-map.json" \
"$REPO/dev-context/project-map.json"

cp "$BASE/code-index.json" \
"$REPO/dev-context/code-index.json"

cp "$BASE/runtime/latest.json" \
"$REPO/dev-context/runtime/latest.json"

cp "$BASE/errors/latest.json" \
"$REPO/dev-context/errors/latest.json"


cd "$REPO"


git add dev-context


if git diff --cached --quiet
then
echo "NO CHANGES"
exit 0
fi


git commit \
-m "Dev Context v3 update $(date -Is)"


git push origin main


echo "SYNC COMPLETE"

SCRIPT


chmod 700 /usr/local/bin/dev-context-sync


echo
echo "=========================================="
echo " DEV ASSISTANT v3 INSTALLED"
echo "=========================================="

echo
echo "Commands:"
echo " dev-context-build"
echo " dev-context-sync"

