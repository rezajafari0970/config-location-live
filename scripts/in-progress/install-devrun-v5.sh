#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/executions" \
"$BASE/changes" \
"$BASE/tests" \
"$BASE/errors" \
"$REPO/dev-context/executions" \
"$REPO/dev-context/changes" \
"$REPO/dev-context/tests"


cat >/usr/local/bin/devrun-v5 <<'SCRIPT'
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
sort |
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
sort |
while read -r f
do
sha256sum "$f"
done > "$AFTER"


END=$(date +%s)


python3 - "$BASE" "$TIME" "$CMD" "$DIR" "$CODE" "$((END-START))" "$OUT" "$ERR" "$BEFORE" "$AFTER" <<'PY'

import json,sys,difflib

(base,time,cmd,directory,code,duration,out,err,before,after)=sys.argv[1:]

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
    json.dump(
        record,
        open(base+"/errors/latest.json","w"),
        indent=2,
        ensure_ascii=False
    )


old=set(open(before).read().splitlines())
new=set(open(after).read().splitlines())

changes={
"time":time,
"changed":list(new-old)
}

json.dump(
changes,
open(base+"/changes/latest.json","w"),
indent=2
)


keywords=[
"test",
"pytest",
"health",
"xray",
"audit",
"check"
]

if any(x in cmd.lower() for x in keywords):

    json.dump(
    record,
    open(base+"/tests/latest.json","w"),
    indent=2,
    ensure_ascii=False
    )

PY


cat "$OUT"
cat "$ERR"

exit "$CODE"

SCRIPT


chmod 700 /usr/local/bin/devrun-v5



cat >/usr/local/bin/dev-context-publish <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"


mkdir -p "$REPO/dev-context"


cp "$BASE/executions/history.jsonl" \
"$REPO/dev-context/executions/history.jsonl"

cp "$BASE/changes/latest.json" \
"$REPO/dev-context/changes/latest.json"

cp "$BASE/tests/latest.json" \
"$REPO/dev-context/tests/latest.json" 2>/dev/null || true

cp "$BASE/errors/latest.json" \
"$REPO/dev-context/errors/latest.json" 2>/dev/null || true


cd "$REPO"

git add dev-context


if git diff --cached --quiet
then
echo "NO CHANGES"
exit 0
fi


git commit \
-m "DevRun Context update $(date -Is)"

git push origin main

echo "PUBLISH COMPLETE"

SCRIPT


chmod 700 /usr/local/bin/dev-context-publish


echo "DEVRUN v5 INSTALLED"

