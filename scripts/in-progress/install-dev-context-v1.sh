#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/dev-context"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE" \
"$REPO/dev-context"


cat >/usr/local/bin/dev-context-build <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/lib/config-location/dev-context"

mkdir -p "$BASE"


echo "[1] Building code index..."

find /opt/config-location \
-type f \
\( -name "*.py" -o -name "*.sh" -o -name "*.service" -o -name "*.php" \) \
2>/dev/null |
while read -r f
do

sha=$(sha256sum "$f" | awk '{print $1}')

size=$(stat -c%s "$f")

mtime=$(stat -c%y "$f")

echo "{\"path\":\"$f\",\"size\":\"$size\",\"mtime\":\"$mtime\",\"sha256\":\"$sha\"}"

done > "$BASE/code-index.jsonl"


echo "[2] Services..."

systemctl list-units \
--type=service \
--no-legend \
2>/dev/null |
grep -Ei \
"config-location|health|country|fetch|lifecycle|panel" \
> "$BASE/services.txt" || true


echo "[3] Runtime..."

ss -lntp \
> "$BASE/ports.txt" 2>/dev/null || true


ps aux |
grep -Ei \
"config-location|xray|python" |
grep -v grep \
> "$BASE/processes.txt" || true


echo "[4] Errors..."

journalctl \
--since "1 hour ago" \
--no-pager \
2>/dev/null |
grep -Ei \
"error|failed|exception|traceback|runtime" |
tail -200 \
> "$BASE/errors.txt" || true


echo "[5] Runtime JSON..."

python3 <<PY

import json,datetime

base="$BASE"

data={
"time":datetime.datetime.now().astimezone().isoformat(),
"code_index":open(base+"/code-index.jsonl").read().splitlines(),
"services":open(base+"/services.txt").read(),
"ports":open(base+"/ports.txt").read(),
"processes":open(base+"/processes.txt").read(),
"errors":open(base+"/errors.txt").read()
}

open(base+"/runtime.json","w").write(
json.dumps(data,indent=2,ensure_ascii=False)
)

PY


echo "DONE"

SCRIPT


chmod 700 /usr/local/bin/dev-context-build


cat >/usr/local/bin/dev-context-sync <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/lib/config-location/dev-context"
REPO="/var/lib/config-location/devlog-github/repo"

dev-context-build

mkdir -p "$REPO/dev-context"

cp "$BASE/runtime.json" \
"$REPO/dev-context/runtime.json"

cp "$BASE/code-index.jsonl" \
"$REPO/dev-context/code-index.jsonl"

cp "$BASE/errors.txt" \
"$REPO/dev-context/errors.txt"


cd "$REPO"

git add dev-context

if git diff --cached --quiet
then
 echo "No changes"
 exit 0
fi


git commit \
-m "Dev Context update $(date -Is)"

git push origin main

echo "SYNC COMPLETE"

SCRIPT


chmod 700 /usr/local/bin/dev-context-sync


echo "DEV CONTEXT V1 INSTALLED"

