#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/dev-assistant-v3"
mkdir -p \
"$BASE/executions" \
"$BASE/changes" \
"$BASE/errors"


cat >/usr/local/bin/devrun-v4 <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/dev-assistant-v3"

START=$(date +%s)
TIME=$(date -Is)

CMD="$*"
DIR="$(pwd)"

BEFORE=$(mktemp)
AFTER=$(mktemp)

find /opt/config-location \
-type f \
2>/dev/null |
while read -r f
do
sha256sum "$f"
done > "$BEFORE"


OUT=$(mktemp)
ERR=$(mktemp)


set +e
"$@" >"$OUT" 2>"$ERR"
CODE=$?
set -e


find /opt/config-location \
-type f \
2>/dev/null |
while read -r f
do
sha256sum "$f"
done > "$AFTER"


END=$(date +%s)


python3 <<PY

import json

base="$BASE"

record={
"time":"$TIME",
"command":"$CMD",
"directory":"$DIR",
"exit_code":$CODE,
"duration":$((END-START)),
"stdout":open("$OUT",errors="ignore").read()[-5000:],
"stderr":open("$ERR",errors="ignore").read()[-5000:]
}


with open(base+"/executions/history.jsonl","a") as f:
    f.write(json.dumps(record,ensure_ascii=False)+"\n")


if $CODE != 0:

    open(base+"/errors/latest.json","w").write(
    json.dumps(record,indent=2,ensure_ascii=False)
    )


PY


diff "$BEFORE" "$AFTER" \
> "$BASE/changes/latest.diff" || true


cat "$OUT"
cat "$ERR"

exit $CODE

SCRIPT


chmod 700 /usr/local/bin/devrun-v4


echo "DEV RUN INTEGRATION v4 INSTALLED"

