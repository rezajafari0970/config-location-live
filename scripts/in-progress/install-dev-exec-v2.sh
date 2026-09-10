#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/executions/history" \
"$BASE/artifacts/cache" \
"$BASE/errors" \
"$BASE/changes" \
"$REPO/dev-context/executions" \
"$REPO/dev-context/errors" \
"$REPO/dev-context/changes"


echo "=============================================="
echo " DEV EXEC v2 INSTALL"
echo "=============================================="


cat >/usr/local/bin/dev-exec <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

TS=$(date +%Y%m%d-%H%M%S)

EXEC="$BASE/executions/history/$TS.json"
STDOUT="$BASE/executions/history/$TS.stdout"
STDERR="$BASE/errors/$TS.stderr"
DIFF="$BASE/changes/$TS.diff"


CMD="$*"

START=$(date -Is)
START_SEC=$(date +%s)


echo "RUN:"
echo "$CMD"


set +e

bash -c "$CMD" \
>"$STDOUT" \
2>"$STDERR"

CODE=$?

set -e


END=$(date -Is)
END_SEC=$(date +%s)


git -C "$REPO" status --short \
>"$DIFF" 2>/dev/null || true


echo "[Artifact Check]"


find "$REPO" \
-type f \
-size +50M \
-not -path "./.git/*" \
> "$BASE/artifacts/large-files.txt" \
2>/dev/null || true


python3 <<PY

import json
import datetime
import os


data={

"time":datetime.datetime.now().astimezone().isoformat(),

"command":"$CMD",

"exit_code":$CODE,

"duration_seconds":
$((END_SEC-START_SEC)),


"stdout":"$STDOUT",

"stderr":"$STDERR",

"diff":"$DIFF"

}


with open("$EXEC","w") as f:
    json.dump(data,f,indent=2)

PY


cp "$EXEC" \
"$REPO/dev-context/executions/latest.json"


cp "$STDERR" \
"$REPO/dev-context/errors/latest.stderr" \
2>/dev/null || true


cp "$DIFF" \
"$REPO/dev-context/changes/latest.diff" \
2>/dev/null || true



cd "$REPO"


if git rev-parse --is-inside-work-tree >/dev/null
then

git add dev-context/executions \
dev-context/errors \
dev-context/changes


git commit \
-m "Execution evidence update $(date -Is)" \
|| true


git push origin main \
|| true

fi


echo
echo "================================"
echo " DEV EXEC COMPLETE"
echo "EXIT: $CODE"
echo "================================"


exit $CODE

SCRIPT


chmod 700 /usr/local/bin/dev-exec


echo "[TEST]"

dev-exec "echo DEV EXEC V2 TEST"


echo
echo "DEV EXEC V2 INSTALLED"

