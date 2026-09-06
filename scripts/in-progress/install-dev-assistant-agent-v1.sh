#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/dev-assistant"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/executions" \
"$BASE/errors" \
"$BASE/system" \
"$BASE/runtime" \
"$REPO/dev-context/executions" \
"$REPO/dev-context/errors" \
"$REPO/dev-context/system" \
"$REPO/dev-context/runtime"


cat >/usr/local/bin/devrun <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/dev-assistant"
LOG="$BASE/executions/history.jsonl"

START=$(date +%s)
TIME=$(date -Is)

CMD="$*"
PWD_NOW="$(pwd)"

TMP=$(mktemp)
ERR=$(mktemp)

set +e
"$@" >"$TMP" 2>"$ERR"
CODE=$?
set -e

END=$(date +%s)
DURATION=$((END-START))

python3 - "$LOG" "$TIME" "$CMD" "$PWD_NOW" "$CODE" "$DURATION" "$TMP" "$ERR" <<'PY'
import json,sys

log,time,cmd,pwd,code,duration,out,err=sys.argv[1:]

record={
"time":time,
"command":cmd,
"directory":pwd,
"exit_code":int(code),
"duration_seconds":int(duration),
"stdout":open(out,errors="ignore").read()[-5000:],
"stderr":open(err,errors="ignore").read()[-5000:]
}

with open(log,"a") as f:
    f.write(json.dumps(record,ensure_ascii=False)+"\n")

print(record["stdout"])

if record["stderr"]:
    print(record["stderr"])

sys.exit(int(code))
PY
SCRIPT


chmod 700 /usr/local/bin/devrun


cat >/usr/local/bin/dev-assistant-audit <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/lib/config-location/dev-assistant"
REPO="/var/lib/config-location/devlog-github/repo"


echo "Collecting runtime..."


systemctl list-units \
--type=service \
--no-legend |
grep config-location \
>"$BASE/system/services.txt" || true


ss -lntp \
>"$BASE/system/ports.txt"


find /opt/config-location \
-maxdepth 2 \
-type f \
>"$BASE/system/paths.txt" 2>/dev/null || true


python3 <<PY

import json,datetime

data={
"time":datetime.datetime.now().isoformat(),
"services":open("$BASE/system/services.txt").read(),
"ports":open("$BASE/system/ports.txt").read(),
"paths":open("$BASE/system/paths.txt").read()
}

open("$BASE/runtime/latest.json","w").write(
json.dumps(data,indent=2,ensure_ascii=False)
)

PY


echo "Audit complete"
SCRIPT

chmod 700 /usr/local/bin/dev-assistant-audit


echo "Dev Assistant Agent v1 installed"

