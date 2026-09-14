#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/lib/config-location/dev-assistant-v3"

mkdir -p \
"$BASE/executions" \
"$BASE/errors"


cat >/usr/local/bin/devrun-v5 <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/dev-assistant-v3"

START=$(date +%s)
TIME=$(date -Is)

CMD="$*"
DIR="$(pwd)"

OUT=$(mktemp)
ERR=$(mktemp)


set +e
"$@" >"$OUT" 2>"$ERR"
CODE=$?
set -e


END=$(date +%s)


python3 - "$BASE" "$TIME" "$CMD" "$DIR" "$CODE" "$((END-START))" "$OUT" "$ERR" <<'PY'

import json,sys

base,time,cmd,directory,code,duration,out,err=sys.argv[1:]

record={
"time":time,
"command":cmd,
"directory":directory,
"exit_code":int(code),
"duration_seconds":int(duration),
"stdout":open(out,errors="ignore").read()[-5000:],
"stderr":open(err,errors="ignore").read()[-5000:]
}

with open(base+"/executions/history.jsonl","a") as f:
    f.write(json.dumps(record,ensure_ascii=False)+"\n")


if int(code)!=0:
    with open(base+"/errors/latest.json","w") as f:
        json.dump(record,f,indent=2,ensure_ascii=False)

print(record["stdout"])

if record["stderr"]:
    print(record["stderr"])

PY


exit "$CODE"

SCRIPT


chmod 700 /usr/local/bin/devrun-v5


echo "DEV RUN FAST MODE ENABLED"

