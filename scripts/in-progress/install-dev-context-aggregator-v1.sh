#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/var/lib/config-location/dev-assistant-v3"
SCANNER="$BASE/code-scanner"
REPO="/var/lib/config-location/devlog-github/repo"

mkdir -p \
"$BASE/aggregator" \
"$REPO/dev-context"


cat >/usr/local/bin/dev-context-aggregate <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/lib/config-location/dev-assistant-v3"
OUT="$BASE/aggregator/latest.json"

python3 <<PY

import json,os,datetime


BASE="$BASE"


def read_json(path,default={}):
    try:
        with open(path) as f:
            return json.load(f)
    except:
        return default


data={

"time":
datetime.datetime.now().astimezone().isoformat(),

"project":
read_json(
BASE+"/project-map.json",
{}
),

"code":
read_json(
BASE+"/code-scanner/index.json",
[]
),

"runtime":
read_json(
BASE+"/runtime/latest.json",
{}
),

"errors":
read_json(
BASE+"/errors/latest.json",
{}
),

"changes":
read_json(
BASE+"/code-scanner/changes.json",
{}
)

}


# executions
try:
    with open(BASE+"/executions/history.jsonl") as f:
        data["executions"]=[
            json.loads(x)
            for x in f.readlines()[-100:]
        ]
except:
    data["executions"]=[]


os.makedirs(
os.path.dirname("$OUT"),
exist_ok=True
)

with open(
"$OUT",
"w"
) as f:
    json.dump(
        data,
        f,
        indent=2,
        ensure_ascii=False
    )


PY


echo "AGGREGATE COMPLETE"

SCRIPT


chmod 700 /usr/local/bin/dev-context-aggregate



cat >/usr/local/bin/dev-context-github-sync <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/var/lib/config-location/dev-assistant-v3"
REPO="/var/lib/config-location/devlog-github/repo"


dev-context-aggregate


cp \
"$BASE/aggregator/latest.json" \
"$REPO/dev-context/latest.json"


cp \
"$BASE/code-scanner/index.json" \
"$REPO/dev-context/code-index.json"


cd "$REPO"


git add dev-context


if git diff --cached --quiet
then
 echo "NO CONTEXT CHANGE"
 exit 0
fi


git commit \
-m "Dev Context Aggregation $(date -Is)"


git push origin main


echo "GITHUB CONTEXT SYNC COMPLETE"

SCRIPT


chmod 700 /usr/local/bin/dev-context-github-sync


echo "DEV CONTEXT AGGREGATOR v1 INSTALLED"

