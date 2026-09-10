#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/executions/history" \
"$BASE/errors" \
"$BASE/changes" \
"$REPO/dev-context/executions" \
"$REPO/dev-context/errors" \
"$REPO/dev-context/changes"


echo "=============================================="
echo " DEV EXECUTION EVIDENCE v1 INSTALL"
echo "=============================================="


cat >/usr/local/bin/dev-exec <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"

START=$(date -Is)
TS=$(date +%Y%m%d-%H%M%S)

OUT="$BASE/executions/history/$TS.json"
STDOUT="$BASE/executions/history/$TS.stdout"
STDERR="$BASE/errors/$TS.stderr"
DIFF="$BASE/changes/$TS.diff"

CMD="$*"

START_SEC=$(date +%s)


echo "Executing:"
echo "$CMD"


set +e

bash -c "$CMD" >"$STDOUT" 2>"$STDERR"

CODE=$?

set -e


END=$(date -Is)
END_SEC=$(date +%s)

DURATION=$((END_SEC-START_SEC))


git -C "$REPO" status --short > "$DIFF" 2>/dev/null || true

COMMIT=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo "unknown")


python3 <<PY

import json
import datetime
import os


data={

"start":"$START",

"end":"$END",

"command":"$CMD",

"exit_code":$CODE,

"duration_seconds":$DURATION,

"stdout_file":"$STDOUT",

"stderr_file":"$STDERR",

"git_commit":"$COMMIT",

"diff_file":"$DIFF"

}


with open("$OUT","w") as f:
    json.dump(
        data,
        f,
        indent=2,
        ensure_ascii=False
    )


PY


cp "$OUT" \
"$REPO/dev-context/executions/latest.json"


cp "$STDERR" \
"$REPO/dev-context/errors/latest.stderr" 2>/dev/null || true


cp "$DIFF" \
"$REPO/dev-context/changes/latest.diff" 2>/dev/null || true


cd "$REPO"


git add dev-context/executions dev-context/errors dev-context/changes


if git diff --cached --quiet
then
    echo "NO CONTEXT CHANGE"
else

git commit \
-m "Execution evidence update $(date -Is)"

git push origin main

fi


echo
echo "================================"
echo " EXECUTION COMPLETE"
echo " EXIT CODE: $CODE"
echo " DURATION: ${DURATION}s"
echo "================================"


exit $CODE

SCRIPT


chmod 700 /usr/local/bin/dev-exec


echo
echo "[TEST] Running evidence test..."


dev-exec "echo DEV EXECUTION EVIDENCE TEST"


echo
echo "=============================================="
echo " DEV EXECUTION EVIDENCE INSTALLED"
echo "=============================================="

